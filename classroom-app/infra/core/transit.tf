# infra/core/transit.tf
#
# Transit Gateway hub of the control-plane region. Media regions (infra/media-edge, one stack per region) connect
# their own regional Transit Gateway to this hub with an inter-region peering attachment, so that SFU and TURN
# nodes reach the control plane privately:
#
#   realtime service  → SFU control RPC (mTLS, TCP 7443)        core → media region
#   SFU / TURN nodes  → state Redis (registries, drain flags)  media region → core
#   TURN agents       → state Redis heartbeats                 media region → core
#
# Media never crosses the Transit Gateway: clients reach SFU and TURN nodes on their Elastic IPs, and
# pipe transports stay inside one region.
#
# Routing is explicit (no default association or propagation):
#
#   route table "control"  associated with the core VPC attachment.
#                          Routes to each media region's VPC CIDR through that region's peering attachment —
#                          added by the media-edge stack of that region, so this stack never changes when a
#                          region is added or removed.
#   route table "media"    associated with every peering attachment (again by the media-edge stacks).
#                          Only route: core VPC CIDR → core VPC attachment. There is no route between media
#                          regions, so a compromised media region cannot reach another one through the hub.
#
# Security groups still decide what may talk (security-groups.tf: state Redis 6379 from the media supernet;
# realtime → media supernet on the SFU control port). The Transit Gateway only provides the path.
#
# Contract with other files of this stack:
#   network.tf        aws_vpc.main · aws_subnet.transit (for_each AZ, /28, dedicated to TGW attachments) ·
#                     aws_route_table.private (for_each AZ)
#   kms.tf            aws_kms_key.logs
#   locals.tf         local.name_prefix  (e.g. "classroom-prod")
#   variables.tf      var.log_retention_days
# Read by infra/media-edge through remote state: the outputs at the end of this file.
#
# Owner: F8 Real-Time Connectivity + F7 Production and Operations.

variable "transit_gateway_asn" {
  description = "Private ASN of the hub Transit Gateway. Must differ from every media-region Transit Gateway ASN."
  type        = number
  default     = 64512

  validation {
    condition     = (var.transit_gateway_asn >= 64512 && var.transit_gateway_asn <= 65534) || (var.transit_gateway_asn >= 4200000000 && var.transit_gateway_asn <= 4294967294)
    error_message = "transit_gateway_asn must be a private ASN (64512-65534 or 4200000000-4294967294)."
  }
}

variable "media_edge_supernet" {
  description = "CIDR that contains every media-region VPC (e.g. 10.64.0.0/10). Routed from the core VPC to the hub; security groups reference it."
  type        = string
  default     = "10.64.0.0/10"

  validation {
    condition     = can(cidrhost(var.media_edge_supernet, 0))
    error_message = "media_edge_supernet must be a valid IPv4 CIDR."
  }
}

# ------------------------------------------------------------------ hub

resource "aws_ec2_transit_gateway" "hub" {
  description                     = "${local.name_prefix} control-plane hub for media regions"
  amazon_side_asn                 = var.transit_gateway_asn
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "disable"
  multicast_support               = "disable"

  tags = {
    Name = "${local.name_prefix}-tgw-hub"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "core" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.main.id
  subnet_ids         = [for subnet in aws_subnet.transit : subnet.id]

  dns_support                                     = "enable"
  ipv6_support                                    = "disable"
  appliance_mode_support                          = "disable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = {
    Name = "${local.name_prefix}-tgw-core"
  }
}

# ------------------------------------------------------------------ route tables

resource "aws_ec2_transit_gateway_route_table" "control" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = {
    Name = "${local.name_prefix}-tgw-rt-control"
  }
}

resource "aws_ec2_transit_gateway_route_table" "media" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = {
    Name = "${local.name_prefix}-tgw-rt-media"
  }
}

resource "aws_ec2_transit_gateway_route_table_association" "core" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.core.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.control.id
}

# Media regions may reach the core VPC and nothing else.
resource "aws_ec2_transit_gateway_route" "media_to_core" {
  destination_cidr_block         = aws_vpc.main.cidr_block
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.core.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.media.id
}

# Core VPC: everything inside the media supernet goes to the hub. The hub then only forwards to regions that have
# attached themselves; addresses of regions that do not exist are dropped at the hub.
resource "aws_route" "core_to_media" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = var.media_edge_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.core]
}

# ------------------------------------------------------------------ flow logs

resource "aws_cloudwatch_log_group" "transit_flow_logs" {
  name              = "/aws/transit-gateway/${local.name_prefix}-hub"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

data "aws_iam_policy_document" "transit_flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.transit.account_id]
    }
  }
}

data "aws_iam_policy_document" "transit_flow_logs_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.transit_flow_logs.arn}:*"]
  }
}

data "aws_caller_identity" "transit" {}

resource "aws_iam_role" "transit_flow_logs" {
  name               = "${local.name_prefix}-tgw-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.transit_flow_logs_assume.json
}

resource "aws_iam_role_policy" "transit_flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.transit_flow_logs.id
  policy = data.aws_iam_policy_document.transit_flow_logs_write.json
}

resource "aws_flow_log" "transit" {
  transit_gateway_id       = aws_ec2_transit_gateway.hub.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.transit_flow_logs.arn
  iam_role_arn             = aws_iam_role.transit_flow_logs.arn
  max_aggregation_interval = 60

  tags = {
    Name = "${local.name_prefix}-tgw-hub"
  }
}

# ------------------------------------------------------------------ outputs for infra/media-edge

output "transit_gateway_id" {
  description = "Hub Transit Gateway; media-edge stacks request an inter-region peering attachment to it."
  value       = aws_ec2_transit_gateway.hub.id
}

output "transit_gateway_region" {
  description = "Region of the hub Transit Gateway (peer_region of the peering attachments)."
  value       = data.aws_region.transit.id # region name; ".id" works on AWS provider 5.x and 6.x
}

output "transit_gateway_control_route_table_id" {
  description = "Media-edge stacks add a route to their VPC CIDR here, targeting their peering attachment."
  value       = aws_ec2_transit_gateway_route_table.control.id
}

output "transit_gateway_media_route_table_id" {
  description = "Media-edge stacks associate their peering attachment (hub side) with this route table."
  value       = aws_ec2_transit_gateway_route_table.media.id
}

output "core_vpc_cidr" {
  description = "Core VPC CIDR; media regions route it to their Transit Gateway."
  value       = aws_vpc.main.cidr_block
}

output "media_edge_supernet" {
  description = "Supernet all media-region VPCs must be allocated from."
  value       = var.media_edge_supernet
}

data "aws_region" "transit" {}