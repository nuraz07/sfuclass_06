# infra/media-edge/prefix-lists.tf
#
# The Elastic IP pools as customer-managed prefix lists, referenced by security groups:
#
#   sfu_public          SFU addresses of this region
#   turn_public         TURN addresses of this region
#   sfu_public_global   SFU addresses of ALL media regions of this environment. The TURN security group allows relay
#                       traffic only to and from this list: a TURN node relays for clients of other regions too (backup
#                       entry in the client's nearest region), but can never be used to reach anything else.
#
# Because the pools are pre-allocated, the lists are static: no runtime process edits them.
#
# Cross-region view: every region publishes its addresses as an SSM parameter in the control-plane region
#   /<name_prefix>/media/public-ips/<region>   {"sfu": [...], "turn": [...]}
# and reads all of them back. A newly added region becomes part of every other region's global list the next time that
# region is applied (terraform.yml applies all regions of an environment in sequence). The same parameters feed
# infra/functions/publish-ip-ranges.
#
# Quota note: a security-group rule referencing a prefix list counts max_entries rules. Raise "Inbound or outbound
# rules per security group" (default 60) above sfu_global_prefix_list_capacity + the group's other rules.
#
# Owner: F8 Real-Time Connectivity.

locals {
  sfu_ips  = sort([for e in aws_eip.sfu : e.public_ip])
  turn_ips = sort([for e in aws_eip.turn : e.public_ip])

  published_path = "/${local.name_prefix}/media/public-ips"

  # SFU addresses of every region (published parameters) plus this region's own, which may not be published yet.
  remote_sfu_ips = flatten([
    for v in nonsensitive(data.aws_ssm_parameters_by_path.published.values) : try(jsondecode(v).sfu, [])
  ])
  global_sfu_ips = sort(distinct(concat(local.sfu_ips, local.remote_sfu_ips)))
}

resource "aws_ec2_managed_prefix_list" "sfu_public" {
  name           = "${local.name_prefix}-sfu-public-${var.region_short}"
  address_family = "IPv4"
  max_entries    = var.eip_pool.sfu

  dynamic "entry" {
    for_each = aws_eip.sfu
    content {
      cidr        = "${entry.value.public_ip}/32"
      description = entry.key
    }
  }
}

resource "aws_ec2_managed_prefix_list" "turn_public" {
  name           = "${local.name_prefix}-turn-public-${var.region_short}"
  address_family = "IPv4"
  max_entries    = var.eip_pool.turn

  dynamic "entry" {
    for_each = aws_eip.turn
    content {
      cidr        = "${entry.value.public_ip}/32"
      description = entry.key
    }
  }
}

resource "aws_ec2_managed_prefix_list" "sfu_public_global" {
  name           = "${local.name_prefix}-sfu-public-all-regions"
  address_family = "IPv4"
  max_entries    = var.sfu_global_prefix_list_capacity

  dynamic "entry" {
    for_each = toset(local.global_sfu_ips)
    content {
      cidr        = "${entry.value}/32"
      description = "sfu"
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.global_sfu_ips) <= var.sfu_global_prefix_list_capacity
      error_message = "More SFU addresses across regions than sfu_global_prefix_list_capacity: raise it (and the security-group rule quota)."
    }
  }
}

# ------------------------------------------------------------------ cross-region publication (control-plane region)

resource "aws_ssm_parameter" "published" {
  provider = aws.core

  name        = "${local.published_path}/${var.region}"
  description = "Public media addresses of ${var.region} (not secret; published for customer allowlists)"
  type        = "String"
  tier        = "Standard"
  value       = jsonencode({ region = var.region, sfu = local.sfu_ips, turn = local.turn_ips })
}

data "aws_ssm_parameters_by_path" "published" {
  provider = aws.core

  path      = local.published_path
  recursive = false
}