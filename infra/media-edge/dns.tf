# infra/media-edge/dns.tf
#
# TURN names in the delegated rtc zone (infra/core/route53.tf, output rtc_zone_id):
#
#   turn-<short>-NN.<rtc_domain>   one A record per TURN address slot (eip-pool.tf). The node that holds the address
#                                  uses this name as coturn server-name and TLS host name; the API hands it out in
#                                  iceServers (server/src/rtc/TurnPoolSelector.js). Covered by *.<rtc_domain>.
#   turn-<region>.<rtc_domain>     multivalue answer over all TURN slots, each with a Route 53 health check (TCP 443):
#                                  answers only with addresses that currently serve TURN over TLS. Used by the pre-join
#                                  probe (GET /rtc/regions) and as a regional fallback name.
#
# SFU nodes get no DNS names: clients receive their addresses in ICE candidates, and the control plane addresses them by
# private IP from the registry.
#
# Owner: F8 Real-Time Connectivity.

locals {
  turn_regional_fqdn = "turn-${var.region}.${local.rtc_domain}"
}

resource "aws_route53_record" "turn_node" {
  for_each = aws_eip.turn

  zone_id = local.core.rtc_zone_id
  name    = "${each.key}.${local.rtc_domain}"
  type    = "A"
  ttl     = 300
  records = [each.value.public_ip]
}

resource "aws_route53_health_check" "turn" {
  for_each = aws_eip.turn

  ip_address        = each.value.public_ip
  port              = 443
  type              = "TCP"
  request_interval  = 30
  failure_threshold = 3

  tags = {
    Name = "${each.key}-tls-443"
  }
}

resource "aws_route53_record" "turn_regional" {
  for_each = aws_eip.turn

  zone_id                          = local.core.rtc_zone_id
  name                             = local.turn_regional_fqdn
  type                             = "A"
  ttl                              = 60
  records                          = [each.value.public_ip]
  set_identifier                   = each.key
  multivalue_answer_routing_policy = true
  health_check_id                  = aws_route53_health_check.turn[each.key].id
}