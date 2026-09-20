# infra/modules/sfu-node-pool/security-group.tf
#
# What may reach an SFU node:
#
#   in   UDP + TCP rtc ports   WebRtcServer ports (rtc_port_base .. + workers - 1) from anywhere — clients directly, and
#                              TURN relays of every media region (they arrive from their Elastic IPs)
#   in   TCP control port      control RPC (mTLS) from the core VPC only (realtime service over the Transit Gateway)
#   in   UDP pipe range        from other SFU nodes of this region only (cascading over private IPs)
#   out  UDP pipe range        to other SFU nodes of this region
#   out  TCP 6379              state Redis in the core VPC (registry heartbeats, drain flags)
#   out  TCP 443               AWS APIs (ECS, ECR, Secrets Manager, SSM, CloudWatch, S3 recordings)
#
# There is deliberately no general egress for media: the SFU is ICE-lite and never initiates media flows. Everything it
# sends to clients and TURN relays answers a flow they opened, which the stateful security group allows.
#
# Owner: F1 Live Classrooms + F8 Real-Time Connectivity (+ security review).

resource "aws_security_group" "sfu" {
  name        = local.name
  description = "SFU nodes ${var.region}: media ports from anywhere, control from the core VPC"
  vpc_id      = var.vpc_id

  tags = {
    Name = local.name
  }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  media_ingress = merge(
    { for proto in ["udp", "tcp"] : "${proto}-ipv4" => { protocol = proto, ipv4 = "0.0.0.0/0", ipv6 = null } },
    var.ipv6 ? { for proto in ["udp", "tcp"] : "${proto}-ipv6" => { protocol = proto, ipv4 = null, ipv6 = "::/0" } } : {},
  )
}

resource "aws_vpc_security_group_ingress_rule" "media" {
  for_each = local.media_ingress

  security_group_id = aws_security_group.sfu.id
  description       = "WebRtcServer ${upper(each.value.protocol)} ports from clients and TURN relays"
  ip_protocol       = each.value.protocol
  from_port         = var.rtc_port_base
  to_port           = local.rtc_port_max
  cidr_ipv4         = each.value.ipv4
  cidr_ipv6         = each.value.ipv6
}

resource "aws_vpc_security_group_ingress_rule" "control" {
  security_group_id = aws_security_group.sfu.id
  description       = "Control RPC (mTLS) from the realtime service in the core VPC"
  ip_protocol       = "tcp"
  from_port         = var.control_port
  to_port           = var.control_port
  cidr_ipv4         = var.control_ingress_cidr
}

resource "aws_vpc_security_group_ingress_rule" "control_health_local" {
  security_group_id = aws_security_group.sfu.id
  description       = "Health endpoint on the control port from inside the media VPC"
  ip_protocol       = "tcp"
  from_port         = var.control_port
  to_port           = var.control_port
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

resource "aws_vpc_security_group_ingress_rule" "pipe" {
  security_group_id            = aws_security_group.sfu.id
  description                  = "Pipe transports from other SFU nodes of this region"
  ip_protocol                  = "udp"
  from_port                    = var.pipe_port_range.min
  to_port                      = var.pipe_port_range.max
  referenced_security_group_id = aws_security_group.sfu.id
}

resource "aws_vpc_security_group_egress_rule" "pipe" {
  security_group_id            = aws_security_group.sfu.id
  description                  = "Pipe transports to other SFU nodes of this region"
  ip_protocol                  = "udp"
  from_port                    = var.pipe_port_range.min
  to_port                      = var.pipe_port_range.max
  referenced_security_group_id = aws_security_group.sfu.id
}

resource "aws_vpc_security_group_egress_rule" "registry" {
  security_group_id = aws_security_group.sfu.id
  description       = "State Redis in the core VPC (Transit Gateway)"
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6379
  cidr_ipv4         = var.control_ingress_cidr
}

resource "aws_vpc_security_group_egress_rule" "aws_apis" {
  security_group_id = aws_security_group.sfu.id
  description       = "AWS APIs over HTTPS (ECS, ECR, Secrets Manager, SSM, CloudWatch, S3)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}