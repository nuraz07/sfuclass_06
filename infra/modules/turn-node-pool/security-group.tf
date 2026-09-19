# infra/modules/turn-node-pool/security-group.tf
#
# What may reach a TURN node and where it may relay to:
#
#   in   UDP 3478, TCP 3478   STUN and TURN from anywhere (clients)
#   in   TCP 443              TURN over TLS from anywhere (clients, Route 53 health checks)
#   in   UDP relay range      only from SFU addresses of all media regions (answers from the SFU)
#   in   TCP 8080             agent /healthz from inside the media VPC
#   out  UDP SFU RTC ports    relay leg, only to SFU addresses of all media regions
#   out  TCP 6379             state Redis in the core VPC (registry heartbeats, drain flags)
#   out  TCP 443              AWS APIs (ECS, ECR, Secrets Manager, SSM, CloudWatch)
#
# There is no other egress: the node cannot be used as a relay into the internet or into any VPC. coturn's own
# denied-peers list (turn/config/denied-peers.conf) is the second, independent layer.
#
# Quota: rules that reference the SFU prefix list count its max_entries against the security-group rule quota.
#
# Owner: F8 Real-Time Connectivity (+ security review).

resource "aws_security_group" "turn" {
  name        = local.name
  description = "TURN nodes ${var.region}: STUN/TURN in, relay only to SFU addresses"
  vpc_id      = var.vpc_id

  tags = {
    Name = local.name
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------ ingress

resource "aws_vpc_security_group_ingress_rule" "stun_turn" {
  for_each = toset(["udp", "tcp"])

  security_group_id = aws_security_group.turn.id
  description       = "STUN/TURN ${upper(each.key)} 3478 from clients"
  ip_protocol       = each.key
  from_port         = 3478
  to_port           = 3478
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "turn_tls" {
  security_group_id = aws_security_group.turn.id
  description       = "TURN over TLS 443 from clients and Route 53 health checks"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "relay_from_sfu" {
  security_group_id = aws_security_group.turn.id
  description       = "Relay ports from SFU addresses (all media regions)"
  ip_protocol       = "udp"
  from_port         = var.relay_port_range.min
  to_port           = var.relay_port_range.max
  prefix_list_id    = var.sfu_prefix_list_id
}

resource "aws_vpc_security_group_ingress_rule" "agent_health" {
  security_group_id = aws_security_group.turn.id
  description       = "Agent health endpoint from inside the media VPC"
  ip_protocol       = "tcp"
  from_port         = local.agent_port
  to_port           = local.agent_port
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

# ------------------------------------------------------------------ egress

resource "aws_vpc_security_group_egress_rule" "relay_to_sfu" {
  security_group_id = aws_security_group.turn.id
  description       = "Relay leg to SFU WebRtcServer ports (all media regions)"
  ip_protocol       = "udp"
  from_port         = var.sfu_rtc_port_range.min
  to_port           = var.sfu_rtc_port_range.max
  prefix_list_id    = var.sfu_prefix_list_id
}

resource "aws_vpc_security_group_egress_rule" "registry" {
  security_group_id = aws_security_group.turn.id
  description       = "State Redis in the core VPC (Transit Gateway)"
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6379
  cidr_ipv4         = var.registry_cidr
}

resource "aws_vpc_security_group_egress_rule" "aws_apis" {
  security_group_id = aws_security_group.turn.id
  description       = "AWS APIs over HTTPS (ECS, ECR, Secrets Manager, SSM, CloudWatch)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}