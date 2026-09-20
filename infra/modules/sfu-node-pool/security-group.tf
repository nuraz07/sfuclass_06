###############################################################################
# infra/modules/sfu-node-pool/security-group.tf
#
# Exactly the media ports, and nothing else.  (F1, F8)
#
# Three rules matter here and they are the three things an SFU security group
# usually gets wrong:
#
#   1. WebRtcServer ports are open to the internet. They have to be: a learner
#      on a home connection sends DTLS-SRTP straight to this address, and
#      there is no proxy or balancer in front. The exposure is bounded by the
#      range being exactly one UDP and one TCP port per worker — not a
#      thousand-port range, and not "all high ports".
#
#   2. The control port is NOT public. It is mTLS-protected and reachable only
#      from the realtime service's security group, across the Transit Gateway.
#      v6 exposed public sfu-* DNS names and a client-visible resolve route;
#      both are gone (Appendix A #5, #6).
#
#   3. Pipe ports for cascading accept traffic only from other SFU nodes in
#      this pool, on private addresses. Node-to-node media never leaves the
#      VPC and is never announced.
###############################################################################

resource "aws_security_group" "this" {
  name        = local.name
  description = "SFU media node: WebRtcServer ports public, control and pipe private"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name             = local.name
    "classroom:role" = "sfu"
  })

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# 1. WebRTC media — public
#
# UDP is the normal path. TCP is the same port number, used by ICE-TCP when a
# network blocks UDP but allows outbound TCP to arbitrary ports. Both are
# required; dropping TCP here is what makes "it works for everyone except the
# school district" happen.
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "webrtc_udp_v4" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = local.rtc_port_min
  to_port           = local.rtc_port_max
  description       = "WebRtcServer UDP, one port per mediasoup worker"

  tags = merge(var.tags, { Name = "${local.name}-webrtc-udp" })
}

resource "aws_vpc_security_group_ingress_rule" "webrtc_tcp_v4" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = local.rtc_port_min
  to_port           = local.rtc_port_max
  description       = "WebRtcServer ICE-TCP, same port numbers as UDP"

  tags = merge(var.tags, { Name = "${local.name}-webrtc-tcp" })
}

resource "aws_vpc_security_group_ingress_rule" "webrtc_udp_v6" {
  count = var.enable_ipv6 ? 1 : 0

  security_group_id = aws_security_group.this.id
  cidr_ipv6         = "::/0"
  ip_protocol       = "udp"
  from_port         = local.rtc_port_min
  to_port           = local.rtc_port_max
  description       = "WebRtcServer UDP over IPv6 (dual-stack subnets)"
}

resource "aws_vpc_security_group_ingress_rule" "webrtc_tcp_v6" {
  count = var.enable_ipv6 ? 1 : 0

  security_group_id = aws_security_group.this.id
  cidr_ipv6         = "::/0"
  ip_protocol       = "tcp"
  from_port         = local.rtc_port_min
  to_port           = local.rtc_port_max
  description       = "WebRtcServer ICE-TCP over IPv6 (dual-stack subnets)"
}

###############################################################################
# 2. Control RPC — realtime service only
#
# createWebRtcTransport, connect, produce, consume, restartIce. mTLS on top of
# this; the security group is the outer boundary, the certificate is the
# authentication.
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "control_from_realtime" {
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.realtime_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.control_port
  to_port                      = var.control_port
  description                  = "mTLS control RPC from the realtime service"

  tags = merge(var.tags, { Name = "${local.name}-control" })
}

# Cross-region: the realtime service lives in the control-plane region and
# reaches this node over the Transit Gateway, so its security group cannot be
# referenced directly. The control-plane private CIDR is the next best bound.
resource "aws_vpc_security_group_ingress_rule" "control_from_control_plane" {
  count = var.control_plane_cidr != null ? 1 : 0

  security_group_id = aws_security_group.this.id
  cidr_ipv4         = var.control_plane_cidr
  ip_protocol       = "tcp"
  from_port         = var.control_port
  to_port           = var.control_port
  description       = "mTLS control RPC from the control-plane VPC over Transit Gateway"
}

###############################################################################
# 3. Pipe transports — this pool only
#
# RouterPipeManager fans a large room out across nodes. Private IPs, SRTP,
# never announced to a client.
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "pipe_from_peers" {
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = aws_security_group.this.id # self
  ip_protocol                  = "udp"
  from_port                    = var.pipe_port_min
  to_port                      = var.pipe_port_max
  description                  = "Node-to-node cascading between SFU nodes in this pool"

  tags = merge(var.tags, { Name = "${local.name}-pipe" })
}

###############################################################################
# 4. Relay traffic from the TURN fleet
#
# A relayed client's packets arrive from a TURN node's relay address, not from
# the client. Bounded to the managed prefix list of TURN Elastic IPs, which
# turn-node-pool maintains.
###############################################################################

resource "aws_vpc_security_group_ingress_rule" "relay_from_turn" {
  security_group_id = aws_security_group.this.id
  prefix_list_id    = var.turn_prefix_list_id
  ip_protocol       = "udp"
  from_port         = local.rtc_port_min
  to_port           = local.rtc_port_max
  description       = "Relayed media from the regional TURN fleet"

  tags = merge(var.tags, { Name = "${local.name}-relay" })
}

###############################################################################
# Egress
#
# Media replies go back to arbitrary client addresses, so egress cannot be
# narrowed for UDP/TCP media. ECR, S3, Secrets Manager and CloudWatch are
# reached through VPC endpoints where available.
###############################################################################

resource "aws_vpc_security_group_egress_rule" "all_v4" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Media replies, image pulls, registry heartbeats, S3 segment upload"
}

resource "aws_vpc_security_group_egress_rule" "all_v6" {
  count = var.enable_ipv6 ? 1 : 0

  security_group_id = aws_security_group.this.id
  cidr_ipv6         = "::/0"
  ip_protocol       = "-1"
  description       = "Media replies over IPv6"
}

###############################################################################
# Published range
#
# The SFU Elastic IPs and this port range are written to media-ip-ranges.json
# by functions/publish-ip-ranges, so enterprise and school IT can allowlist the
# platform without guessing. Changing rtc_port_base or workers_per_node changes
# that published document — treat it as a customer-facing change.
###############################################################################