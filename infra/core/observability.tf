###############################################################################
# infra/core/observability.tf
#
# Dashboards, alarms and log retention. Nothing else.  (F7)
#
# v6 -> v7 correction: v6 defined the scheduled jobs here. Scheduling is not
# observability — EventBridge Scheduler now lives in scheduler.tf, and this
# file only watches things.
#
# The alarms below are the ones that page someone (§12.1). Anything that does
# not have a first action in ops/runbooks/on-call.md does not belong here; it
# belongs on a dashboard.
#
# Media-plane alarms (TURN canary, EIP pool, per-region ICE failure) are
# defined in infra/media-edge/observability.tf, next to the resources they
# watch, and route to the same SNS topic exported from this stack.
###############################################################################

###############################################################################
# Notification targets
###############################################################################

resource "aws_sns_topic" "pager" {
  name              = "${local.name_prefix}-pager"
  kms_master_key_id = aws_kms_key.secrets.arn
  tags              = local.tags
}

resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-alerts" # ticket, not a phone call
  kms_master_key_id = aws_kms_key.secrets.arn
  tags              = local.tags
}

###############################################################################
# Log retention
#
# Individual groups are declared next to their service (ecs-api.tf,
# ecs-realtime.tf, ...). This is the application log group and the retention
# policy that applies to the rest.
###############################################################################

resource "aws_cloudwatch_log_group" "app" {
  name              = "/classroom/${var.environment}/app"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
  tags              = local.tags
}

# Business metrics arrive as EMF inside the application log stream, so the
# metric namespace is created by the logger, not here. These filters exist for
# the few counters that are easier to derive from log lines than from EMF.
resource "aws_cloudwatch_log_metric_filter" "unhandled_rejections" {
  name           = "${local.name_prefix}-unhandled-rejections"
  log_group_name = aws_cloudwatch_log_group.api.name
  pattern        = "{ $.msg = \"unhandled rejection\" }"

  metric_transformation {
    name      = "UnhandledRejections"
    namespace = local.metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

###############################################################################
# Alarms that page someone
###############################################################################

# API 5xx > 2 % over 5 minutes -> check the release, roll back the task def.
resource "aws_cloudwatch_metric_alarm" "api_5xx_rate" {
  alarm_name          = "${local.name_prefix}-api-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 2
  treat_missing_data  = "notBreaching"
  alarm_description   = "API 5xx above 2% — runbook: ops/runbooks/rollback.md"

  metric_query {
    id          = "error_rate"
    expression  = "100 * (errors / MAX([requests, 1]))"
    label       = "5xx rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 300
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.this.arn_suffix
        TargetGroup  = aws_lb_target_group.api.arn_suffix
      }
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 300
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.this.arn_suffix
        TargetGroup  = aws_lb_target_group.api.arn_suffix
      }
    }
  }

  alarm_actions = [aws_sns_topic.pager.arn]
  ok_actions    = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

# Any task failing /readyz for 3 minutes -> check RDS and Redis health.
resource "aws_cloudwatch_metric_alarm" "readiness_failures" {
  for_each = toset(["api", "realtime"])

  alarm_name          = "${local.name_prefix}-${each.key}-unhealthy-hosts"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "${each.key} tasks failing readiness — check RDS and Redis"

  dimensions = {
    LoadBalancer = aws_lb.this.arn_suffix
    TargetGroup  = each.key == "api" ? aws_lb_target_group.api.arn_suffix : aws_lb_target_group.realtime.arn_suffix
  }

  alarm_actions = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

# ICE failure rate > 2 % over 10 minutes. Emitted by the API as EMF
# (observability/metrics.js) and aggregated per media region.
resource "aws_cloudwatch_metric_alarm" "ice_failure_rate" {
  alarm_name          = "${local.name_prefix}-ice-failure-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 2
  treat_missing_data  = "notBreaching"
  alarm_description   = "Transports failing ICE — check SFU security groups, EIPs, TURN canary (ops/runbooks/turn-incident.md)"

  metric_query {
    id          = "failure_rate"
    expression  = "100 * (failed / MAX([attempts, 1]))"
    label       = "ICE failure rate (%)"
    return_data = true
  }

  metric_query {
    id = "failed"
    metric {
      namespace   = local.metric_namespace
      metric_name = "IceFailed"
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "attempts"
    metric {
      namespace   = local.metric_namespace
      metric_name = "IceAttempts"
      period      = 300
      stat        = "Sum"
    }
  }

  alarm_actions = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

# Relay share doubling against the 7-day baseline usually means the direct UDP
# path to the SFU broke — ports, NACLs or a dropped EIP association.
resource "aws_cloudwatch_metric_alarm" "relay_share_spike" {
  alarm_name          = "${local.name_prefix}-relay-share-spike"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  threshold_metric_id = "baseline"
  treat_missing_data  = "notBreaching"
  alarm_description   = "Relayed share spiked — likely a broken direct path to the SFU"

  metric_query {
    id          = "relay_share"
    return_data = true
    metric {
      namespace   = local.metric_namespace
      metric_name = "RelayShare"
      period      = 300
      stat        = "Average"
    }
  }

  metric_query {
    id         = "baseline"
    expression = "ANOMALY_DETECTION_BAND(relay_share, 3)"
    label      = "relay share expected band"
  }

  alarm_actions = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

# The state cluster must never evict. 70 % is the point at which there is
# still time to scale it.
resource "aws_cloudwatch_metric_alarm" "redis_state_memory" {
  alarm_name          = "${local.name_prefix}-redis-state-memory"
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  period              = 300
  statistic           = "Maximum"
  threshold           = 70
  alarm_description   = "State Redis above 70% — it must never evict; scale the cluster"

  dimensions = { ReplicationGroupId = aws_elasticache_replication_group.state.id }

  alarm_actions = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

# Any eviction on the state cluster is already a lost job or seat.
resource "aws_cloudwatch_metric_alarm" "redis_state_evictions" {
  alarm_name          = "${local.name_prefix}-redis-state-evictions"
  namespace           = "AWS/ElastiCache"
  metric_name         = "Evictions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "State Redis evicted a key — parameter group drift or memory exhaustion"

  dimensions = { ReplicationGroupId = aws_elasticache_replication_group.state.id }

  alarm_actions = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "database_cpu" {
  alarm_name          = "${local.name_prefix}-rds-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU high — find the query, check pool caps"

  dimensions = { DBInstanceIdentifier = aws_db_instance.primary.id }

  alarm_actions = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  count = var.rds_read_replica_enabled ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-replica-lag"
  namespace           = "AWS/RDS"
  metric_name         = "ReplicaLag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  period              = 60
  statistic           = "Maximum"
  threshold           = 30
  alarm_description   = "Read replica lagging — feeds and reporting are stale"

  dimensions = { DBInstanceIdentifier = aws_db_instance.replica[0].id }

  alarm_actions = [aws_sns_topic.alerts.arn]
  tags          = local.tags
}

# Queue depth: transcode lag is the user-visible one (a lesson recording that
# never appears), so it pages; the others raise a ticket.
resource "aws_cloudwatch_metric_alarm" "transcode_lag" {
  alarm_name          = "${local.name_prefix}-transcode-lag"
  namespace           = local.metric_namespace
  metric_name         = "QueueWaiting"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  period              = 300
  statistic           = "Maximum"
  threshold           = var.transcode_queue_alarm_threshold
  alarm_description   = "Transcode backlog — scale the worker service, inspect dead letters"

  dimensions = { queue = "transcode" }

  alarm_actions = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "chat_delivery_latency" {
  alarm_name          = "${local.name_prefix}-chat-latency-p95"
  namespace           = local.metric_namespace
  metric_name         = "ChatDeliveryLatency"
  extended_statistic  = "p95"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 300
  threshold           = 1000
  alarm_description   = "Chat p95 above 1 s — check the sharded Redis adapter and socket fan-out"

  alarm_actions = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

resource "aws_cloudwatch_metric_alarm" "certificate_expiry" {
  alarm_name          = "${local.name_prefix}-acm-expiry"
  namespace           = "AWS/CertificateManager"
  metric_name         = "DaysToExpiry"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  period              = 86400
  statistic           = "Minimum"
  threshold           = 21
  alarm_description   = "Certificate under 21 days — renewal should be automatic, investigate"

  dimensions = { CertificateArn = aws_acm_certificate.primary.arn }

  alarm_actions = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

###############################################################################
# Composite: "is the product broken right now"
#
# Feeds the status page and gives on-call one thing to look at before the
# individual alarms.
###############################################################################

resource "aws_cloudwatch_composite_alarm" "service_degraded" {
  alarm_name        = "${local.name_prefix}-service-degraded"
  alarm_description = "One or more user-visible subsystems are failing"

  alarm_rule = join(" OR ", [
    "ALARM(${aws_cloudwatch_metric_alarm.api_5xx_rate.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.ice_failure_rate.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.chat_delivery_latency.alarm_name})",
    "ALARM(${aws_cloudwatch_metric_alarm.redis_state_memory.alarm_name})",
  ])

  alarm_actions = [aws_sns_topic.pager.arn]
  ok_actions    = [aws_sns_topic.pager.arn]
  tags          = local.tags
}

###############################################################################
# Dashboard
###############################################################################

resource "aws_cloudwatch_dashboard" "platform" {
  dashboard_name = "${local.name_prefix}-platform"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Live classrooms and ICE"
          region = var.region
          view   = "timeSeries"
          metrics = [
            [local.metric_namespace, "RoomsLive", { stat = "Maximum" }],
            [".", "IceAttempts", { stat = "Sum" }],
            [".", "IceFailed", { stat = "Sum" }],
            [".", "RelayShare", { stat = "Average", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "API and realtime"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }],
            [".", "TargetResponseTime", ".", ".", { stat = "p95" }],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", { stat = "Sum" }],
            ["AWS/ECS", "CPUUtilization", "ServiceName", aws_ecs_service.api.name, "ClusterName", aws_ecs_cluster.this.name],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Data plane"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.primary.id],
            [".", "DatabaseConnections", ".", "."],
            ["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "ReplicationGroupId", aws_elasticache_replication_group.state.id],
            [".", "CacheHitRate", "ReplicationGroupId", aws_elasticache_replication_group.cache.id],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Queues"
          region = var.region
          view   = "timeSeries"
          metrics = [
            [local.metric_namespace, "QueueWaiting", "queue", "transcode"],
            ["...", "notify"],
            ["...", "chat"],
            ["...", "recording"],
          ]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "Recent errors"
          region = var.region
          query  = "SOURCE '${aws_cloudwatch_log_group.api.name}' | fields @timestamp, msg, err.message, traceId | filter level >= 50 | sort @timestamp desc | limit 50"
        }
      },
    ]
  })
}