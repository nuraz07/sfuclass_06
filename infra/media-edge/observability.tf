# infra/media-edge/observability.tf
#
# Regional monitoring of the media plane. CloudWatch alarms can only notify an SNS topic in their own region, so every
# media region has its own alarm topic (<alarm_topic_name>-media-<short>) with the same subscriptions as the core one.
#
# Metrics (all emitted as CloudWatch Embedded Metric Format, no agents):
#   Classroom/Turn       ActiveAllocations · RelayEgressMbps · LoadRatio · ProbeSuccess · ProbeRttMs · Draining
#                        dimensions [Region] and [Region, Node]            turn/agent/src/metricsBridge.js
#   Classroom/Sfu        LoadScore · Consumers · EgressMbps · CpuMax
#                        dimensions [Region] and [Region, Node]            server/src/observability/metrics.js (sfu role)
#   Classroom/MediaEdge  FreeEips  dimensions [Region, Pool]               infra/functions/node-lifecycle
#   canary alarm         module.canary (1-minute TURN allocation from outside the VPC)
#
# Alarms here page for conditions that need a human; per-node failures are handled automatically (registry heartbeat
# expiry, ECS replacement, ICE restart). Capacity alarms fire before autoscaling runs out of headroom.
#
# Owner: F8 Real-Time Connectivity + F7 Production and Operations.

# ------------------------------------------------------------------ KMS for logs and the alarm topic

data "aws_iam_policy_document" "logs_key" {
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
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.region}:${local.account_id}:*"]
    }
  }

  statement {
    sid       = "AlarmNotifications"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "${local.name_prefix} media-region logs and alarms (${var.region})"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.logs_key.json
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.name_prefix}-media-logs"
  target_key_id = aws_kms_key.logs.key_id
}

# ------------------------------------------------------------------ alarm topic

resource "aws_sns_topic" "alarms" {
  name              = "${var.alarm_topic_name}-media-${var.region_short}"
  kms_master_key_id = aws_kms_key.logs.arn
}

data "aws_iam_policy_document" "alarms_topic" {
  statement {
    sid       = "CloudWatchAlarms"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.alarms_topic.json
}

resource "aws_sns_topic_subscription" "alarms" {
  for_each = { for s in var.alarm_subscriptions : "${s.protocol}:${s.endpoint}" => s }

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = each.value.protocol
  endpoint  = each.value.endpoint
}

# ------------------------------------------------------------------ alarms

locals {
  alarm_prefix = "${local.name_prefix}-media-${var.region}"
  alarm_actions = {
    alarm_actions = [aws_sns_topic.alarms.arn]
    ok_actions    = [aws_sns_topic.alarms.arn]
  }
}

resource "aws_cloudwatch_metric_alarm" "sfu_load_high" {
  alarm_name          = "${local.alarm_prefix}-sfu-load-high"
  alarm_description   = "Average SFU load score above 0.8 for 15 min: autoscaling is not keeping up or max_nodes is reached. Runbook: ops/runbooks/sfu-incident.md"
  namespace           = "Classroom/Sfu"
  metric_name         = "LoadScore"
  dimensions          = { Region = var.region }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 0.8
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions.alarm_actions
  ok_actions          = local.alarm_actions.ok_actions
}

resource "aws_cloudwatch_metric_alarm" "turn_node_saturated" {
  alarm_name          = "${local.alarm_prefix}-turn-node-saturated"
  alarm_description   = "A TURN node above 80 % of its planned capacity for 5 min. Runbook: ops/runbooks/turn-incident.md"
  namespace           = "Classroom/Turn"
  metric_name         = "LoadRatio"
  dimensions          = { Region = var.region }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 0.8
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions.alarm_actions
  ok_actions          = local.alarm_actions.ok_actions
}

# Missing data is breaching: no TURN node reporting at all is the worst case, not a quiet one.
resource "aws_cloudwatch_metric_alarm" "turn_probe_failing" {
  alarm_name          = "${local.alarm_prefix}-turn-probe-failing"
  alarm_description   = "A TURN node's self-probe (STUN + TURN allocation over UDP and TLS) failing for 3 min, or no node reporting. Runbook: ops/runbooks/turn-incident.md"
  namespace           = "Classroom/Turn"
  metric_name         = "ProbeSuccess"
  dimensions          = { Region = var.region }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = local.alarm_actions.alarm_actions
  ok_actions          = local.alarm_actions.ok_actions
}

resource "aws_cloudwatch_metric_alarm" "eip_pool_exhausted" {
  for_each = toset(["sfu", "turn"])

  alarm_name          = "${local.alarm_prefix}-${each.key}-eip-pool-exhausted"
  alarm_description   = "No free Elastic IP left in the ${each.key} pool for 15 min: the next node cannot launch. Grow eip_pool.${each.key} and announce the new addresses (ops/runbooks/customer-firewall.md)."
  namespace           = "Classroom/MediaEdge"
  metric_name         = "FreeEips"
  dimensions          = { Region = var.region, Pool = each.key }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions.alarm_actions
  ok_actions          = local.alarm_actions.ok_actions
}

# ------------------------------------------------------------------ dashboard

resource "aws_cloudwatch_dashboard" "media" {
  dashboard_name = "${local.name_prefix}-media-${var.region}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "SFU load score", region = var.region, stat = "Average", period = 60
          metrics = [["Classroom/Sfu", "LoadScore", "Region", var.region], [".", ".", ".", ".", { stat = "Maximum" }]]
          annotations = { horizontal = [
            { label = "scaling target", value = var.sfu.target_load_score },
            { label = "unhealthy", value = var.sfu.max_load_score },
          ] }
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "SFU consumers and egress", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["Classroom/Sfu", "Consumers", "Region", var.region],
            [".", "EgressMbps", ".", ".", { yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title = "TURN allocations and relayed egress", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["Classroom/Turn", "ActiveAllocations", "Region", var.region],
            [".", "RelayEgressMbps", ".", ".", { yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title = "TURN load ratio (max node) and probe", region = var.region, period = 60
          metrics = [
            ["Classroom/Turn", "LoadRatio", "Region", var.region, { stat = "Maximum" }],
            [".", "ProbeSuccess", ".", ".", { stat = "Minimum" }],
            [".", "ProbeRttMs", ".", ".", { stat = "p90", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title = "Free Elastic IPs", region = var.region, stat = "Minimum", period = 300
          metrics = [
            ["Classroom/MediaEdge", "FreeEips", "Region", var.region, "Pool", "sfu"],
            ["...", "turn"],
          ]
        }
      },
      {
        type = "alarm", x = 12, y = 12, width = 12, height = 6
        properties = {
          title = "Alarms"
          alarms = concat(
            [
              aws_cloudwatch_metric_alarm.sfu_load_high.arn,
              aws_cloudwatch_metric_alarm.turn_node_saturated.arn,
              aws_cloudwatch_metric_alarm.turn_probe_failing.arn,
            ],
            [for a in aws_cloudwatch_metric_alarm.eip_pool_exhausted : a.arn],
            var.canary.enabled ? [module.canary.alarm_arn] : [],
          )
        }
      },
    ]
  })
}