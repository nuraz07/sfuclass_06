###############################################################################
# infra/core/network.tf
#
# Control-plane VPC.  (F7)
#
# v6 -> v7 corrections:
#   - 3 availability zones instead of 2. Two AZs leave no sane spread for ECS
#     capacity and no quorum-friendly placement; the loss of one AZ took out
#     half the fleet.
#   - one NAT gateway per AZ instead of a single shared one. A single NAT is a
#     single point of failure for every outbound call (Stripe, APNs, ECR
#     pulls on a cold start) and a cross-AZ data charge on every byte.
#   - explicit public/private split; nothing that holds data has a route to an
#     internet gateway.
#
# There are no media subnets here. SFU and TURN nodes live in the per-region
# media-edge stacks and reach this VPC over Transit Gateway with control
# traffic only (transit.tf).
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  az_count = 3
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  # /16 split into /20s: room for growth without renumbering.
  public_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block                       = var.vpc_cidr
  enable_dns_support               = true
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name_prefix}-igw" })
}

###############################################################################
# Subnets
###############################################################################

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # ALB and NAT get explicit addresses

  tags = merge(local.tags, {
    Name                     = "${local.name_prefix}-public-${local.azs[count.index]}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, {
    Name = "${local.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

###############################################################################
# NAT — one per AZ
#
# var.single_nat_gateway is true only in dev (core.tfvars), where the cost of
# three NAT gateways is not justified and an AZ outage is not an incident.
###############################################################################

locals {
  nat_count = var.single_nat_gateway ? 1 : local.az_count
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = merge(local.tags, { Name = "${local.name_prefix}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.tags, { Name = "${local.name_prefix}-nat-${local.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Routing
###############################################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name_prefix}-rt-public" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route" "public_internet_v6" {
  route_table_id              = aws_route_table.public.id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = local.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ so each AZ egresses through its own NAT.
resource "aws_route_table" "private" {
  count  = local.az_count
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-rt-private-${local.azs[count.index]}" })
}

resource "aws_route" "private_nat" {
  count = local.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "private" {
  count          = local.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

###############################################################################
# Transit Gateway routes to the media regions
#
# Control traffic only: node heartbeats to the state Redis cluster and mTLS
# RPC from realtime to SFU control ports. Media never crosses this.
###############################################################################

# var.media_region_cidrs is a map, e.g. { "us-east-1" = "10.20.0.0/16" }.
# One route per (private route table x media region).
resource "aws_route" "private_to_media" {
  for_each = {
    for pair in setproduct(range(local.az_count), keys(var.media_region_cidrs)) :
    "${pair[0]}-${pair[1]}" => {
      rt_index = pair[0]
      cidr     = var.media_region_cidrs[pair[1]]
    }
  }

  route_table_id         = aws_route_table.private[each.value.rt_index].id
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.core]
}

###############################################################################
# Flow logs
###############################################################################

resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "REJECT" # ACCEPT at this volume is mostly noise and cost
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn

  tags = merge(local.tags, { Name = "${local.name_prefix}-flow-logs" })
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${local.name_prefix}/flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn

  tags = local.tags
}

###############################################################################
# Default security group — closed
#
# AWS creates one with an allow-all self rule. Leaving it in place means any
# resource launched without an explicit group silently gets VPC-wide access.
###############################################################################

resource "aws_default_security_group" "closed" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-default-closed" })
}

###############################################################################
# Consumers
#
# data.tf builds the RDS / ElastiCache / OpenSearch subnet groups from
# aws_subnet.private; alb.tf places the load balancer in aws_subnet.public.
# The stack-level outputs (vpc_id, subnet ids, CIDR) live in outputs.tf so
# media-edge can read them through remote state.
###############################################################################