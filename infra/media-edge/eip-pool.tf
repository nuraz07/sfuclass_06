# infra/media-edge/eip-pool.tf
#
# Pre-allocated Elastic IPs: one per possible node, created before any node exists.
#
#   Why a pool instead of per-instance addresses:
#     - every media address of the platform is known in advance and published (media-ip-ranges.json,
#       infra/functions/publish-ip-ranges) so schools and companies can allowlist it once;
#     - security groups, prefix lists and DNS are static (prefix-lists.tf, dns.tf) — no Lambda edits them at runtime;
#     - a replaced node gets an address the allowlists already contain.
#   Sizes (tfvars): sfu = max_nodes + 1 (instance refresh) · turn = 2 × max_nodes + 1 (blue/green deploys).
#
# Each address carries its slot identity as tags. The node-lifecycle Lambda picks a free address of the right pool at
# instance launch, associates it, and — for TURN — copies TurnNodeName / TurnHostname / TurnPublicIp onto the instance,
# where turn/bootstrap/render-config.sh reads them through IMDS.
#
# prevent_destroy: removing an address breaks customer allowlists. Shrinking a pool is a deliberate, announced change
# (ops/runbooks/customer-firewall.md): remove the lifecycle guard in a reviewed change, then apply.
#
# Owner: F8 Real-Time Connectivity.

locals {
  sfu_slots  = [for i in range(var.eip_pool.sfu) : format("sfu-%s-%02d", var.region_short, i + 1)]
  turn_slots = [for i in range(var.eip_pool.turn) : format("turn-%s-%02d", var.region_short, i + 1)]
}

resource "aws_eip" "sfu" {
  for_each = toset(local.sfu_slots)

  domain           = "vpc"
  public_ipv4_pool = var.eip_pool.public_ipv4_pool

  tags = {
    Name      = each.key
    MediaPool = "sfu"
    Slot      = each.key
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_eip" "turn" {
  for_each = toset(local.turn_slots)

  domain           = "vpc"
  public_ipv4_pool = var.eip_pool.public_ipv4_pool

  tags = {
    Name         = each.key
    MediaPool    = "turn"
    Slot         = each.key
    TurnNodeName = each.key
    TurnHostname = "${each.key}.${local.rtc_domain}"
  }

  lifecycle {
    prevent_destroy = true
  }
}