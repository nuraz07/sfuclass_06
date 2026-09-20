// classroom-app/infra/core/secrets.tf
/**
 * Secrets  (F7, F8)  [EXT]
 *
 * Every secret the platform uses, as a Secrets Manager secret with a
 * customer-managed KMS key. No secret is ever a literal in a task definition,
 * an image layer or git; config/secrets.js fetches them at boot by name, scoped
 * to the process role.
 *
 * Version 7 adds three things:
 *
 *   TURN secret ring    the shared secret the TURN REST credentials are signed
 *                       with. It exists in exactly two places: the API's ring
 *                       (api and realtime tasks) and the TURN nodes. It is
 *                       replicated into every media region, because a TURN node
 *                       fetches it from its own region at boot, and it is
 *                       rotated in three phases by
 *                       functions/turn-secret-rotation: stage the new version
 *                       (nodes accept both), switch signing, retire the old one
 *                       after the maximum credential TTL. No live session
 *                       breaks, and rotation is the emergency kill switch for
 *                       credentials that cannot be revoked individually.
 *
 *   ICE opaque-id pepper  the HMAC pepper behind the pseudonymous TURN
 *                         username, so no user id, e-mail or name ever reaches
 *                         a coturn log. Rotating it only changes future
 *                         pseudonyms, so it is not on a rotation schedule.
 *
 *   Control-plane CA    the private CA plus the server and client certificates
 *                       for the mTLS control RPC between the realtime service
 *                       and SFU nodes. Per-role material: the SFU holds the
 *                       server certificate, realtime the client certificate,
 *                       and both trust the same CA.
 *
 * TURN TLS (for turns:443) is not here: ACM certificates cannot be installed on
 * EC2, so functions/acme-renewer obtains *.<rtc_domain> through ACME DNS-01 and
 * writes it into its own secret, replicated the same way.
 */

locals {
  # One replica per media region so a node never crosses a region to boot.
  secret_replica_regions = distinct([
    for media_region in var.media_regions : media_region.region
    if media_region.enabled && media_region.region != var.region
  ])

  secret_prefix = "${var.project}/${var.environment}"
}

# ---------------------------------------------------------------------------
# Control-plane secrets (no replicas: only this region's tasks read them)
# ---------------------------------------------------------------------------

locals {
  control_plane_secrets = {
    "jwt/private-key"        = "RS256 signing key for access tokens; api only"
    "jwt/public-key"         = "RS256 verification key; api and realtime"
    "cookie-secret"          = "Signing secret for the refresh cookie"
    "database/url"           = "PostgreSQL connection string, writer"
    "database/read-url"      = "PostgreSQL connection string, read replica"
    "redis/state-url"        = "State cluster (noeviction): queues, registries, limits"
    "redis/cache-url"        = "Cache cluster (volatile-lru): presence, entitlements"
    "cdn/private-key"        = "CloudFront signed URL key"
    "cdn/key-pair-id"        = "CloudFront key pair id"
    "stripe/secret-key"      = "Stripe API key"
    "stripe/webhook-secret"  = "Stripe webhook signing secret"
    "opensearch/url"         = "OpenSearch endpoint with credentials"
  }
}

resource "aws_secretsmanager_secret" "control_plane" {
  for_each = local.control_plane_secrets

  name        = "${local.secret_prefix}/${each.key}"
  description = each.value
  kms_key_id  = aws_kms_key.secrets.arn

  # Long enough to undo a mistake, short enough that a name can be reused.
  recovery_window_in_days = var.environment == "prod" ? 30 : 7

  tags = merge(local.tags, { Name = "${local.secret_prefix}/${each.key}" })
}

# ---------------------------------------------------------------------------
# [V7] TURN secret ring
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "turn_shared_secret" {
  name        = "${local.secret_prefix}/turn/shared-secret"
  description = "TURN REST shared secret. AWSCURRENT signs; AWSPREVIOUS is accepted until phase 3."
  kms_key_id  = aws_kms_key.secrets.arn

  recovery_window_in_days = var.environment == "prod" ? 30 : 7

  dynamic "replica" {
    for_each = toset(local.secret_replica_regions)

    content {
      region = replica.value
      # The replica is encrypted with the region's own key; media-edge creates it.
    }
  }

  tags = merge(local.tags, { Name = "${local.secret_prefix}/turn/shared-secret" })
}

resource "random_password" "turn_shared_secret" {
  length  = 64
  special = false
}

/**
 * Seeded once. After that the rotation Lambda owns the value, which is why the
 * version is ignored: a Terraform apply must never put a stale secret back and
 * lock out every relayed client.
 */
resource "aws_secretsmanager_secret_version" "turn_shared_secret" {
  secret_id     = aws_secretsmanager_secret.turn_shared_secret.id
  secret_string = random_password.turn_shared_secret.result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret_rotation" "turn_shared_secret" {
  secret_id           = aws_secretsmanager_secret.turn_shared_secret.id
  rotation_lambda_arn = aws_lambda_function.turn_secret_rotation.arn

  rotation_rules {
    automatically_after_days = var.turn_secret_rotation_days
  }

  # Phase 3 waits out the longest credential that can still be in flight, so a
  # rotation interval below the maximum TTL would retire a secret that is still
  # signing live allocations.
  depends_on = [aws_lambda_permission.turn_secret_rotation]
}

# ---------------------------------------------------------------------------
# [V7] ICE opaque-id pepper
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "ice_opaque_id_pepper" {
  name        = "${local.secret_prefix}/ice/opaque-id-pepper"
  description = "HMAC pepper for pseudonymous TURN usernames; api and realtime only"
  kms_key_id  = aws_kms_key.secrets.arn

  recovery_window_in_days = var.environment == "prod" ? 30 : 7
  tags                    = merge(local.tags, { Name = "${local.secret_prefix}/ice/opaque-id-pepper" })
}

resource "random_password" "ice_opaque_id_pepper" {
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret_version" "ice_opaque_id_pepper" {
  secret_id     = aws_secretsmanager_secret.ice_opaque_id_pepper.id
  secret_string = random_password.ice_opaque_id_pepper.result

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# [V7] SFU control plane: private CA and mTLS material
# ---------------------------------------------------------------------------

locals {
  control_plane_pki = {
    "sfu-control/ca"                = { description = "CA both ends of the control RPC trust", replicate = true }
    "sfu-control/sfu/tls-cert"      = { description = "SFU control server certificate", replicate = true }
    "sfu-control/sfu/tls-key"       = { description = "SFU control server key", replicate = true }
    "sfu-control/realtime/tls-cert" = { description = "realtime client certificate", replicate = false }
    "sfu-control/realtime/tls-key"  = { description = "realtime client key", replicate = false }
  }
}

resource "aws_secretsmanager_secret" "control_plane_pki" {
  for_each = local.control_plane_pki

  name        = "${local.secret_prefix}/${each.key}"
  description = each.value.description
  kms_key_id  = aws_kms_key.secrets.arn

  recovery_window_in_days = var.environment == "prod" ? 30 : 7

  dynamic "replica" {
    # Only what an SFU node reads at boot is replicated; the realtime client
    # material never leaves the control-plane region.
    for_each = each.value.replicate ? toset(local.secret_replica_regions) : toset([])

    content {
      region = replica.value
    }
  }

  tags = merge(local.tags, { Name = "${local.secret_prefix}/${each.key}" })
}

# ---------------------------------------------------------------------------
# [V7] TURN TLS certificate (written by the ACME renewer, not by Terraform)
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "turn_tls" {
  name        = "${local.secret_prefix}/turn/tls"
  description = "ACME certificate and key for *.${var.rtc_domain}, renewed by functions/acme-renewer"
  kms_key_id  = aws_kms_key.secrets.arn

  recovery_window_in_days = var.environment == "prod" ? 30 : 7

  dynamic "replica" {
    for_each = toset(local.secret_replica_regions)

    content {
      region = replica.value
    }
  }

  tags = merge(local.tags, { Name = "${local.secret_prefix}/turn/tls" })
}

# ---------------------------------------------------------------------------
# Collected for iam.tf and the task definitions
# ---------------------------------------------------------------------------

locals {
  secret_arns = merge(
    { for key, secret in aws_secretsmanager_secret.control_plane : key => secret.arn },
    { for key, secret in aws_secretsmanager_secret.control_plane_pki : key => secret.arn },
    {
      "turn/shared-secret"     = aws_secretsmanager_secret.turn_shared_secret.arn
      "ice/opaque-id-pepper"   = aws_secretsmanager_secret.ice_opaque_id_pepper.arn
      "turn/tls"               = aws_secretsmanager_secret.turn_tls.arn
    },
  )

  # What each role's task is allowed to read. The SFU is not in this stack, but
  # its policy is built from the same map in modules/sfu-node-pool.
  secret_arns_by_role = {
    api = [
      local.secret_arns["jwt/private-key"],
      local.secret_arns["jwt/public-key"],
      local.secret_arns["cookie-secret"],
      local.secret_arns["database/url"],
      local.secret_arns["database/read-url"],
      local.secret_arns["redis/state-url"],
      local.secret_arns["redis/cache-url"],
      local.secret_arns["cdn/private-key"],
      local.secret_arns["cdn/key-pair-id"],
      local.secret_arns["stripe/secret-key"],
      local.secret_arns["stripe/webhook-secret"],
      local.secret_arns["opensearch/url"],
      local.secret_arns["turn/shared-secret"],
      local.secret_arns["ice/opaque-id-pepper"],
    ]
    realtime = [
      local.secret_arns["jwt/public-key"],
      local.secret_arns["database/url"],
      local.secret_arns["redis/state-url"],
      local.secret_arns["redis/cache-url"],
      local.secret_arns["turn/shared-secret"],
      local.secret_arns["ice/opaque-id-pepper"],
      local.secret_arns["sfu-control/ca"],
      local.secret_arns["sfu-control/realtime/tls-cert"],
      local.secret_arns["sfu-control/realtime/tls-key"],
    ]
    worker = [
      local.secret_arns["database/url"],
      local.secret_arns["database/read-url"],
      local.secret_arns["redis/state-url"],
      local.secret_arns["redis/cache-url"],
      local.secret_arns["opensearch/url"],
    ]
  }
}