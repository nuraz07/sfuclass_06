# infra/media-edge/secrets-replica.tf
#
# Secrets the media nodes read, served from this region:
#
#   turn_shared_secret     TURN REST secret ring (AWSCURRENT / AWSPENDING / AWSPREVIOUS) → coturn static-auth-secret
#   turn_tls               {"fullchain","privkey"} for TURN over TLS 443 (infra/functions/acme-renewer)
#   redis_state_url        state Redis (registries, drain flags) for SFU nodes, TURN agents and the lifecycle Lambda
#   sfu_control_node_tls   {"cert","key"} of the SFU control server (CN/SAN sfu.control.internal)
#   sfu_control_ca         CA that signs realtime and SFU control certificates
#
# The primaries live in the core region (infra/core/secrets.tf). Replication is a property of the primary secret, so
# the core declares one replica per media region — encrypted with this region's key:
#
#   replica { region = "<media region>", kms_key_id = "alias/<name_prefix>-media-secrets" }
#
# Replicas keep the primary's name and random suffix, so their ARN is the primary ARN with the region replaced.
# Rotation (infra/functions/turn-secret-rotation, acme-renewer) writes the primary only; versions and staging labels
# replicate within seconds. Nodes in the core region itself read the primaries (no replica, core key).
#
# Region onboarding order: apply this stack (creates the key + alias) → apply the core stack with the new region in
# var.media_regions (creates the replicas) → nodes pass their bootstrap. The check below reports a missing replica.
#
# Owner: F8 Real-Time Connectivity (+ security review).

locals {
  is_core_region = var.region == var.core_remote_state.region

  primary_secret_arns = {
    turn_shared_secret   = local.core.turn_shared_secret_arn
    turn_tls             = local.core.turn_tls_secret_arn
    redis_state_url      = local.core.redis_state_url_secret_arn
    sfu_control_node_tls = local.core.sfu_control_node_tls_secret_arn
    sfu_control_ca       = local.core.sfu_control_ca_secret_arn
  }

  replica_arns = {
    for name, arn in local.primary_secret_arns :
    name => local.is_core_region ? arn : replace(arn, ":secretsmanager:${var.core_remote_state.region}:", ":secretsmanager:${var.region}:")
  }

  # Key the nodes need for kms:Decrypt: the core secrets key in the core region, this region's key elsewhere.
  secrets_kms_key_arn = local.is_core_region ? local.core.secrets_kms_key_arn : aws_kms_key.secrets[0].arn
}

data "aws_iam_policy_document" "secrets_key" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "SecretsManagerReplicas"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account_id}:root"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_kms_key" "secrets" {
  count = local.is_core_region ? 0 : 1

  description             = "${local.name_prefix} media-region secret replicas (${var.region})"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.secrets_key.json
}

resource "aws_kms_alias" "secrets" {
  count = local.is_core_region ? 0 : 1

  name          = "alias/${local.name_prefix}-media-secrets"
  target_key_id = aws_kms_key.secrets[0].key_id
}

# Reports (does not fail) when the core stack has not created the replicas yet.
check "secret_replicas_present" {
  data "aws_secretsmanager_secrets" "replicas" {
    filter {
      name   = "name"
      values = [for arn in values(local.replica_arns) : regex("secret:(.+)-[A-Za-z0-9]{6}$", arn)[0]]
    }
  }

  assert {
    condition     = alltrue([for arn in values(local.replica_arns) : contains(data.aws_secretsmanager_secrets.replicas.arns, arn)])
    error_message = "Not every secret the media nodes need is replicated to ${var.region} yet. Add ${var.region} to var.media_regions of the core stack and apply it."
  }
}