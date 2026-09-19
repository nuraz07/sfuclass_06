# infra/modules/connectivity-canary/main.tf
#
# Outside-in TURN check of one media region: a CloudWatch Synthetics canary (infra/functions/turn-canary/canary.js)
# runs every minute from the public internet — no VPC — like a real client:
#
#   resolve turn-<region>.<rtc_domain> (health-checked multivalue name) → for every node:
#   UDP 3478: STUN binding, TURN allocation with a freshly minted credential, relayed address = node address,
#             permission for a public peer, denied peers refused, release
#   TLS 443:  certificate chain + host name + at least 7 days left, then the same allocation over TURN-over-TLS
#
# The alarm (var.alarm_name) goes to ALARM after var.failed_runs_to_alarm failed minutes, or when the canary stops
# reporting. deploy-turn.yml refuses to deploy into a region whose canary is in ALARM and checks it again after new
# nodes join.
#
# Code: the bundle from infra/functions (`npm run build:turn-canary`), zipped with the nodejs/node_modules layout
# Synthetics expects.
#
# Owner: F8 Real-Time Connectivity.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4, < 3.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  # Synthetics names: lowercase, max 21 characters, unique per account and region.
  canary_name  = "turn-${substr(sha1("${var.name_prefix}/${var.region}"), 0, 12)}"
  artifact_dir = coalesce(var.artifact_dir, "${path.module}/../../functions/dist/turn-canary")
}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = local.artifact_dir
  output_path = "${path.root}/.build/${local.canary_name}.zip"
}

# ------------------------------------------------------------------ artifacts bucket

resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "${local.canary_name}-artifacts-"
  force_destroy = true # only run artifacts (logs, reports), expired after the log retention anyway
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.logs_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-runs"
    status = "Enabled"
    filter {
      prefix = ""
    }
    expiration {
      days = var.log_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "artifacts_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_tls_only.json
}

# ------------------------------------------------------------------ IAM

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "canary" {
  name               = "${var.name_prefix}-${local.canary_name}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "canary" {
  statement {
    sid       = "Artifacts"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }
  statement {
    sid       = "ArtifactsBucket"
    actions   = ["s3:GetBucketLocation", "s3:ListAllMyBuckets"]
    resources = ["*"]
  }
  statement {
    sid       = "ArtifactsEncryption"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.logs_kms_key_arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/cwsyn-${local.canary_name}-*"]
  }
  statement {
    sid       = "SyntheticsMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["CloudWatchSynthetics"]
    }
  }
  statement {
    sid       = "TurnSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.turn_secret_arn]
  }
  statement {
    sid       = "DecryptTurnSecret"
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "canary" {
  name   = "turn-canary"
  role   = aws_iam_role.canary.id
  policy = data.aws_iam_policy_document.canary.json
}

# ------------------------------------------------------------------ canary

resource "aws_synthetics_canary" "turn" {
  name                     = local.canary_name
  artifact_s3_location     = "s3://${aws_s3_bucket.artifacts.id}/"
  execution_role_arn       = aws_iam_role.canary.arn
  runtime_version          = var.runtime_version
  handler                  = "canary.handler"
  zip_file                 = data.archive_file.code.output_path
  start_canary             = var.enabled
  success_retention_period = min(var.log_retention_days, 455)
  failure_retention_period = min(var.log_retention_days, 455)
  delete_lambda            = true

  schedule {
    expression = var.schedule
  }

  run_config {
    timeout_in_seconds = 50
    memory_in_mb       = 960
    active_tracing     = false
    environment_variables = {
      TURN_REGIONAL_HOST = var.regional_host
      TURN_REALM         = var.realm
      TURN_SECRET_ARN    = var.turn_secret_arn
      PROBE_PEER_IP      = var.probe_peer_ip
    }
  }

  artifact_config {
    s3_encryption {
      encryption_mode = "SSE_KMS"
      kms_key_arn     = var.logs_kms_key_arn
    }
  }

  tags = {
    Name        = "${var.name_prefix}-turn-canary-${var.region}"
    MediaRegion = var.region
  }

  depends_on = [aws_iam_role_policy.canary]
}

# ------------------------------------------------------------------ alarm

resource "aws_cloudwatch_metric_alarm" "canary" {
  count = var.enabled ? 1 : 0

  alarm_name          = var.alarm_name
  alarm_description   = "TURN canary failing in ${var.region}: allocation over UDP 3478 or TLS 443 failed, a node relays to a denied peer, or the certificate expires within 7 days. Runbook: ops/runbooks/turn-incident.md"
  namespace           = "CloudWatchSynthetics"
  metric_name         = "SuccessPercent"
  dimensions          = { CanaryName = aws_synthetics_canary.turn.name }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = var.failed_runs_to_alarm
  datapoints_to_alarm = var.failed_runs_to_alarm
  threshold           = 100
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # a canary that stopped running is not a healthy region
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}

# ------------------------------------------------------------------ outputs

output "alarm_name" {
  description = "Canary alarm name (null when the canary is disabled)."
  value       = var.enabled ? aws_cloudwatch_metric_alarm.canary[0].alarm_name : null
}

output "alarm_arn" {
  description = "Canary alarm ARN (null when the canary is disabled)."
  value       = var.enabled ? aws_cloudwatch_metric_alarm.canary[0].arn : null
}

output "canary_name" {
  description = "Synthetics canary name."
  value       = aws_synthetics_canary.turn.name
}