# infra/media-edge/transit.tf
#
# Connects this media region to the control-plane hub (infra/core/transit.tf) for CONTROL traffic only:
#
#   realtime (core VPC)      → SFU control port on the nodes' private IPs (mTLS)
#   SFU / TURN nodes, Lambda → state Redis in the core VPC (registries, drain flags)
#
# Media never uses this path: clients and TURN relays reach SFU nodes on their Elastic IPs.
#
#   media VPC ── VPC attachment ── regional TGW ══ inter-region peering ══ hub TGW ── core VPC
#
# This stack owns both ends of its peering: it requests the attachment here, accepts it in the core region (provider
# aws.core), associates it with the hub's "media" route table and adds its own VPC CIDR to the hub's "control" route
# table. Adding or removing a region therefore never changes the core stack. There are no routes between media
# regions: each region can reach the core VPC and nothing else.
#
# Owner: F8 Real-Time Connectivity + F7 Production and Operations.

resource "aws_ec2_transit_gateway" "media" {
  description                     = "${local.name_prefix} media region ${var.region}"
  amazon_side_asn                 = var.transit_gateway_asn
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "disable"
  multicast_support               = "disable"

  tags = {
    Name = "${local.name_prefix}-tgw-${var.region_short}"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "media" {
  transit_gateway_id                              = aws_ec2_transit_gateway.media.id
  vpc_id                                          = aws_vpc.media.id
  subnet_ids                                      = [for s in aws_subnet.transit : s.id]
  dns_support                                     = "enable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = {
    Name = "${local.name_prefix}-tgw-${var.region_short}-vpc"
  }
}

# ------------------------------------------------------------------ peering to the hub

resource "aws_ec2_transit_gateway_peering_attachment" "hub" {
  transit_gateway_id      = aws_ec2_transit_gateway.media.id
  peer_transit_gateway_id = local.core.transit_gateway_id
  peer_region             = local.core.transit_gateway_region
  peer_account_id         = local.account_id

  tags = {
    Name = "${local.name_prefix}-peering-${var.region_short}-hub"
  }
}

resource "aws_ec2_transit_gateway_peering_attachment_accepter" "hub" {
  provider = aws.core

  transit_gateway_attachment_id = aws_ec2_transit_gateway_peering_attachment.hub.id

  tags = {
    Name = "${local.name_prefix}-peering-${var.region_short}-hub"
  }
}

# Hub side: traffic arriving from this region is routed by the hub's "media" table (core VPC only) …
resource "aws_ec2_transit_gateway_route_table_association" "hub_media" {
  provider = aws.core

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.hub.transit_gateway_attachment_id
  transit_gateway_route_table_id = local.core.transit_gateway_media_route_table_id
}

# … and the core VPC reaches this region through the hub's "control" table.
resource "aws_ec2_transit_gateway_route" "hub_to_region" {
  provider = aws.core

  destination_cidr_block         = var.vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment_accepter.hub.transit_gateway_attachment_id
  transit_gateway_route_table_id = local.core.transit_gateway_control_route_table_id
}

# ------------------------------------------------------------------ regional routing

resource "aws_ec2_transit_gateway_route_table" "media" {
  transit_gateway_id = aws_ec2_transit_gateway.media.id

  tags = {
    Name = "${local.name_prefix}-tgw-${var.region_short}-rt"
  }
}

resource "aws_ec2_transit_gateway_route_table_association" "vpc" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.media.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.media.id
}

resource "aws_ec2_transit_gateway_route_table_association" "peering" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.media.id

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.hub]
}

resource "aws_ec2_transit_gateway_route" "to_core" {
  destination_cidr_block         = local.core.core_vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_peering_attachment.hub.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.media.id

  depends_on = [aws_ec2_transit_gateway_peering_attachment_accepter.hub]
}

resource "aws_ec2_transit_gateway_route" "to_vpc" {
  destination_cidr_block         = var.vpc_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.media.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.media.id
}

# VPC side: only the core VPC CIDR goes to the Transit Gateway.
resource "aws_route" "public_to_core" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = local.core.core_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.media.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.media]
}

resource "aws_route" "private_to_core" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = local.core.core_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.media.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.media]
}