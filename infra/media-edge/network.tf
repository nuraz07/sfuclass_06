# infra/media-edge/network.tf
#
# Network of one media region (architecture doc, sections 4.3, 4.4 and 7):
#
#   public media subnets   one per AZ · SFU and TURN nodes with Elastic IPs · default route to the Internet Gateway
#                          (media never goes through a NAT or load balancer) · route to the core VPC via the regional
#                          Transit Gateway for control traffic (realtime → SFU control port, nodes → state Redis)
#   private subnets        one per AZ · node-lifecycle Lambda and interface endpoints; no internet route at all —
#                          AWS APIs through VPC endpoints, state Redis through the Transit Gateway
#   transit subnets        one /28 per AZ · only the Transit Gateway attachment's network interfaces
#
# Instances launch with an automatically assigned public IPv4 so the ECS agent can register immediately; the
# node-lifecycle Lambda then associates the node's Elastic IP from the pool, which replaces it. Bootstrap scripts wait
# until the Elastic IP is in place before a node announces anything (turn/bootstrap/render-config.sh).
#
# Address plan inside var.vpc_cidr (for a /16):  public /20 × AZ · private /20 × AZ · transit /28 × AZ in the last /20.
#
# Owner: F8 Real-Time Connectivity + F7 Production and Operations.

locals {
  azs         = { for i, az in var.availability_zone_ids : az => i }
  enable_ipv6 = var.sfu.ipv6
}

resource "aws_vpc" "media" {
  cidr_block                       = var.vpc_cidr
  enable_dns_support               = true
  enable_dns_hostnames             = true
  assign_generated_ipv6_cidr_block = local.enable_ipv6

  tags = {
    Name = "${local.name_prefix}-media-${var.region_short}"
  }
}

# Nothing may use the default security group.
resource "aws_default_security_group" "media" {
  vpc_id = aws_vpc.media.id

  tags = {
    Name = "${local.name_prefix}-media-${var.region_short}-default-unused"
  }
}

resource "aws_internet_gateway" "media" {
  vpc_id = aws_vpc.media.id

  tags = {
    Name = "${local.name_prefix}-media-${var.region_short}"
  }
}

# ------------------------------------------------------------------ subnets

resource "aws_subnet" "public" {
  for_each = local.azs

  vpc_id                          = aws_vpc.media.id
  availability_zone_id            = each.key
  cidr_block                      = cidrsubnet(var.vpc_cidr, 4, each.value)
  map_public_ip_on_launch         = true
  ipv6_cidr_block                 = local.enable_ipv6 ? cidrsubnet(aws_vpc.media.ipv6_cidr_block, 8, each.value) : null
  assign_ipv6_address_on_creation = local.enable_ipv6

  tags = {
    Name = "${local.name_prefix}-media-public-${each.key}"
    Tier = "public-media"
  }
}

resource "aws_subnet" "private" {
  for_each = local.azs

  vpc_id               = aws_vpc.media.id
  availability_zone_id = each.key
  cidr_block           = cidrsubnet(var.vpc_cidr, 4, 4 + each.value)

  tags = {
    Name = "${local.name_prefix}-media-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_subnet" "transit" {
  for_each = local.azs

  vpc_id               = aws_vpc.media.id
  availability_zone_id = each.key
  cidr_block           = cidrsubnet(cidrsubnet(var.vpc_cidr, 4, 15), 8, each.value)

  tags = {
    Name = "${local.name_prefix}-media-transit-${each.key}"
    Tier = "transit"
  }
}

# ------------------------------------------------------------------ routing

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.media.id

  tags = {
    Name = "${local.name_prefix}-media-public"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.media.id
}

resource "aws_route" "public_internet_ipv6" {
  count = local.enable_ipv6 ? 1 : 0

  route_table_id              = aws_route_table.public.id
  destination_ipv6_cidr_block = "::/0"
  gateway_id                  = aws_internet_gateway.media.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private and transit subnets: local VPC + core VPC (transit.tf) only.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.media.id

  tags = {
    Name = "${local.name_prefix}-media-private"
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "transit" {
  for_each = aws_subnet.transit

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ------------------------------------------------------------------ VPC endpoints for the private subnets

resource "aws_security_group" "endpoints" {
  name        = "${local.name_prefix}-media-endpoints"
  description = "Interface endpoints: HTTPS from inside the media VPC"
  vpc_id      = aws_vpc.media.id

  tags = {
    Name = "${local.name_prefix}-media-endpoints"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from the media VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.vpc_cidr
}

# The lifecycle Lambda needs EC2 (EIP association, tags), Auto Scaling (hooks), Secrets Manager (state Redis URL),
# CloudWatch (metrics, logs) and STS; nodes in the public subnets use the same endpoints through private DNS.
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(["ec2", "autoscaling", "secretsmanager", "logs", "monitoring", "sts"])

  vpc_id              = aws_vpc.media.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.endpoints.id]

  tags = {
    Name = "${local.name_prefix}-media-${each.key}"
  }
}

# ------------------------------------------------------------------ flow logs

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/${local.name_prefix}-media-${var.region_short}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name_prefix}-media-${var.region_short}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "media" {
  vpc_id                   = aws_vpc.media.id
  traffic_type             = "REJECT" # rejected traffic is what incident response needs; ALL would be media-volume sized
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.vpc_flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60
}