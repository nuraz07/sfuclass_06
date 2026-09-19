# infra/core/ecs-realtime.tf
#
# The realtime service (server/src/realtime.js): Socket.IO signalling, chat, presence and Yjs collaboration,
# the only service allowed to reach SFU control ports. Separate from the api service because it holds long-lived
# connections with a different memory profile and scaling signal (architecture doc, section 8.1).
#
# Owned here, next to the service:
#   task + execution roles (least privilege), log group, task definition (bootstrap revision), ECS service,
#   ALB target group + listener rule (host ws.<domain>), autoscaling on connections per task.
# Images are owned by .github/workflows/deploy-realtime.yml: the service ignores task_definition changes and CI
# registers new revisions with the signed image digest. Terraform only creates the first revision.
#
# Contract with other files of this stack:
#   network.tf          aws_subnet.private (for_each AZ)
#   security-groups.tf  aws_security_group.realtime (ingress 8080 from the ALB SG; egress: RDS, Redis, OpenSearch,
#                       HTTPS endpoints, media supernet TCP 7443 for SFU control)
#   alb.tf              aws_lb_listener.https (idle_timeout on the ALB must exceed the 25 s Socket.IO ping)
#   ecs-cluster.tf      aws_ecs_cluster.main (capacity providers FARGATE and FARGATE_SPOT)
#   ecr.tf              aws_ecr_repository.api (Dockerfile.api image; used by api AND realtime)
#   kms.tf              aws_kms_key.logs · aws_kms_key.secrets
#   secrets.tf          aws_secretsmanager_secret.{database_url, redis_state_url, redis_cache_url, jwt_public_key,
#                       turn_shared_secret, ice_opaque_id_pepper, sfu_control_realtime_tls, sfu_control_ca}
#                       sfu_control_realtime_tls is JSON {"cert": "...", "key": "..."}
#   locals.tf           local.name_prefix
#   Dockerfile.api      WORKDIR contains src/; RDS CA bundle at /etc/ssl/certs/rds-global-bundle.pem (PGSSLMODE=verify-full)
#   variables.tf        var.environment · var.log_retention_days · var.media_regions · var.rtc_domain
#
# Owner: F1 Live Classrooms + F7 Production and Operations.

variable "realtime_hostname" {
  description = "Public host name of the realtime service behind the ALB, e.g. ws.example.com."
  type        = string
}

variable "realtime_allowed_origins" {
  description = "Browser origins allowed to open WebSockets (ALLOWED_ORIGINS), e.g. [\"https://app.example.com\"]."
  type        = list(string)
}

variable "realtime_listener_rule_priority" {
  description = "Priority of the realtime host rule on the HTTPS listener (unique per listener)."
  type        = number
  default     = 20
}

variable "realtime_cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 1024
}

variable "realtime_memory" {
  description = "Fargate task memory (MiB)."
  type        = number
  default     = 2048
}

variable "realtime_cpu_architecture" {
  description = "ARM64 (Graviton, default) or X86_64. The api image must be built for this architecture."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.realtime_cpu_architecture)
    error_message = "realtime_cpu_architecture must be ARM64 or X86_64."
  }
}

variable "realtime_min_tasks" {
  description = "Minimum tasks; at least one per availability zone."
  type        = number
  default     = 3
}

variable "realtime_max_tasks" {
  description = "Maximum tasks."
  type        = number
  default     = 30
}

variable "realtime_target_connections_per_task" {
  description = "Scaling target: average open sockets per task (metric Classroom/Realtime ActiveConnections)."
  type        = number
  default     = 8000
}

variable "realtime_spot_weight" {
  description = "FARGATE_SPOT weight next to FARGATE weight 1. Spot interruptions reconnect every socket of a task, so keep 0 in production."
  type        = number
  default     = 0
}

variable "realtime_initial_image_tag" {
  description = "Image tag for the first task definition revision only; deploy-realtime.yml owns the image afterwards."
  type        = string
  default     = "bootstrap"
}

variable "otel_collector_image" {
  description = "AWS Distro for OpenTelemetry collector image (pinned version; bump deliberately)."
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.40.0"
}

variable "ice_default_region" {
  description = "ICE_DEFAULT_REGION: media region used for probes without a usable region hint. Defaults to the first media region."
  type        = string
  default     = null
}

variable "ice_region_fallbacks" {
  description = "ICE_REGION_FALLBACKS as a map, e.g. { \"eu-central-1\" = [\"us-east-1\"] }."
  type        = map(list(string))
  default     = {}
}

variable "realtime_enable_execute_command" {
  description = "Allow ECS Exec into realtime tasks (audited through CloudTrail). Keep false in production."
  type        = bool
  default     = false
}

locals {
  realtime_name      = "${local.name_prefix}-realtime"
  realtime_port      = 8080
  realtime_container = "realtime"

  realtime_secret_arns = {
    DATABASE_URL         = aws_secretsmanager_secret.database_url.arn
    REDIS_STATE_URL      = aws_secretsmanager_secret.redis_state_url.arn
    REDIS_CACHE_URL      = aws_secretsmanager_secret.redis_cache_url.arn
    JWT_PUBLIC_KEY       = aws_secretsmanager_secret.jwt_public_key.arn
    ICE_OPAQUE_ID_PEPPER = aws_secretsmanager_secret.ice_opaque_id_pepper.arn
    SFU_CONTROL_TLS_CERT = "${aws_secretsmanager_secret.sfu_control_realtime_tls.arn}:cert::"
    SFU_CONTROL_TLS_KEY  = "${aws_secretsmanager_secret.sfu_control_realtime_tls.arn}:key::"
    SFU_CONTROL_CA       = aws_secretsmanager_secret.sfu_control_ca.arn
  }

  # Whole secrets the execution role may read (JSON-key references above point into these).
  realtime_secret_resources = [
    aws_secretsmanager_secret.database_url.arn,
    aws_secretsmanager_secret.redis_state_url.arn,
    aws_secretsmanager_secret.redis_cache_url.arn,
    aws_secretsmanager_secret.jwt_public_key.arn,
    aws_secretsmanager_secret.ice_opaque_id_pepper.arn,
    aws_secretsmanager_secret.sfu_control_realtime_tls.arn,
    aws_secretsmanager_secret.sfu_control_ca.arn,
  ]

  realtime_environment = {
    NODE_ENV                    = "production"
    SERVICE_ROLE                = "realtime"
    SERVICE_NAME                = "realtime"
    PORT                        = tostring(local.realtime_port)
    LOG_LEVEL                   = "info"
    ALLOWED_ORIGINS             = join(",", var.realtime_allowed_origins)
    REDIS_TLS                   = "true"
    PGSSLMODE                   = "verify-full"
    NODE_EXTRA_CA_CERTS         = "/etc/ssl/certs/rds-global-bundle.pem"
    REALTIME_DRAIN_WINDOW_MS    = "60000"
    ICE_RTC_DOMAIN              = var.rtc_domain
    ICE_MEDIA_REGIONS           = join(",", var.media_regions)
    ICE_DEFAULT_REGION          = coalesce(var.ice_default_region, var.media_regions[0])
    ICE_REGION_FALLBACKS        = join(";", [for region, targets in var.ice_region_fallbacks : "${region}=${join(",", targets)}"])
    TURN_SHARED_SECRET_ARN      = aws_secretsmanager_secret.turn_shared_secret.arn
    OTEL_EXPORTER_OTLP_ENDPOINT = "http://127.0.0.1:4318"
    RELEASE_SHA                 = var.realtime_initial_image_tag
  }
}

# ------------------------------------------------------------------ IAM

data "aws_iam_policy_document" "realtime_ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.realtime.partition}:ecs:${data.aws_region.realtime.id}:${data.aws_caller_identity.realtime.account_id}:*"]
    }
  }
}

data "aws_partition" "realtime" {}
data "aws_region" "realtime" {}
data "aws_caller_identity" "realtime" {}

# Execution role: pull the image, write logs, inject the task secrets at start.
resource "aws_iam_role" "realtime_execution" {
  name               = "${local.realtime_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.realtime_ecs_assume.json
}

data "aws_iam_policy_document" "realtime_execution" {
  statement {
    sid       = "PullImage"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.api.arn]
  }
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.realtime.arn}:*"]
  }
  statement {
    sid       = "InjectSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.realtime_secret_resources
  }
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.secrets.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.realtime.id}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "realtime_execution" {
  name   = "execution"
  role   = aws_iam_role.realtime_execution.id
  policy = data.aws_iam_policy_document.realtime_execution.json
}

# Task role: what the running process may do. The TURN secret ring reads AWSCURRENT and AWSPREVIOUS itself
# (TurnSecretRing.js) so rotation takes effect without a redeploy; traces and metrics go through the collector.
resource "aws_iam_role" "realtime_task" {
  name               = "${local.realtime_name}-task"
  assume_role_policy = data.aws_iam_policy_document.realtime_ecs_assume.json
}

data "aws_iam_policy_document" "realtime_task" {
  statement {
    sid       = "TurnSecretRing"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.turn_shared_secret.arn]
  }
  statement {
    sid       = "DecryptTurnSecret"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.secrets.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.realtime.id}.amazonaws.com"]
    }
  }
  statement {
    sid = "Telemetry"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"]
  }
  dynamic "statement" {
    for_each = var.realtime_enable_execute_command ? [1] : []
    content {
      sid = "EcsExec"
      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "realtime_task" {
  name   = "task"
  role   = aws_iam_role.realtime_task.id
  policy = data.aws_iam_policy_document.realtime_task.json
}

# ------------------------------------------------------------------ logs

resource "aws_cloudwatch_log_group" "realtime" {
  name              = "/ecs/${local.realtime_name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

# ------------------------------------------------------------------ task definition (bootstrap revision)

resource "aws_ecs_task_definition" "realtime" {
  family                   = local.realtime_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.realtime_cpu
  memory                   = var.realtime_memory
  execution_role_arn       = aws_iam_role.realtime_execution.arn
  task_role_arn            = aws_iam_role.realtime_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.realtime_cpu_architecture
  }

  volume {
    name = "tmp"
  }

  container_definitions = jsonencode([
    {
      name                   = local.realtime_container
      image                  = "${aws_ecr_repository.api.repository_url}:${var.realtime_initial_image_tag}"
      essential              = true
      command                = ["node", "--import", "./src/observability/tracing.js", "./src/realtime.js"]
      readonlyRootFilesystem = true
      stopTimeout            = 120
      portMappings           = [{ containerPort = local.realtime_port, protocol = "tcp", name = "http" }]
      environment            = [for key in sort(keys(local.realtime_environment)) : { name = key, value = local.realtime_environment[key] }]
      secrets                = [for key in sort(keys(local.realtime_secret_arns)) : { name = key, valueFrom = local.realtime_secret_arns[key] }]
      mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
      ulimits                = [{ name = "nofile", softLimit = 65535, hardLimit = 65535 }]
      linuxParameters        = { initProcessEnabled = true }
      healthCheck = {
        command     = ["CMD", "node", "-e", "fetch('http://127.0.0.1:${local.realtime_port}/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
      dependsOn = [{ containerName = "otel-collector", condition = "START" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.realtime.name
          awslogs-region        = data.aws_region.realtime.id
          awslogs-stream-prefix = "realtime"
          mode                  = "non-blocking"
          max-buffer-size       = "4m"
        }
      }
    },
    {
      # AWS Distro for OpenTelemetry: OTLP from tracing.js → X-Ray, EMF metrics → CloudWatch.
      name                   = "otel-collector"
      image                  = var.otel_collector_image
      essential              = false
      command                = ["--config=/etc/ecs/ecs-default-config.yaml"]
      readonlyRootFilesystem = false
      memoryReservation      = 128
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.realtime.name
          awslogs-region        = data.aws_region.realtime.id
          awslogs-stream-prefix = "otel"
          mode                  = "non-blocking"
        }
      }
    },
  ])

  lifecycle {
    # Same rules config/ice.config.js enforces at boot — caught here at plan time instead of as a crash loop.
    precondition {
      condition = alltrue(flatten([
        for region, targets in var.ice_region_fallbacks :
        [contains(var.media_regions, region), [for t in targets : contains(var.media_regions, t) && t != region]]
      ]))
      error_message = "ice_region_fallbacks may only name regions from var.media_regions, and never a region as its own fallback."
    }
    precondition {
      condition     = var.ice_default_region == null || contains(var.media_regions, coalesce(var.ice_default_region, "-"))
      error_message = "ice_default_region must be one of var.media_regions."
    }
  }
}

# ------------------------------------------------------------------ load balancer routing

resource "aws_lb_target_group" "realtime" {
  name                 = substr("${local.realtime_name}-tg", 0, 32)
  port                 = local.realtime_port
  protocol             = "HTTP"
  protocol_version     = "HTTP1" # WebSocket upgrade requires HTTP/1.1 to the target
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 90 # below the 120 s stop timeout; realtime.js drains sockets within 60 s
  slow_start           = 60 # a new task receives reconnect waves gradually after scale-out

  health_check {
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Sticky sessions keep a client's reconnects on the same task; the Redis adapter makes them optional.
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "realtime" {
  listener_arn = aws_lb_listener.https.arn
  priority     = var.realtime_listener_rule_priority

  condition {
    host_header {
      values = [var.realtime_hostname]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.realtime.arn
  }
}

# ------------------------------------------------------------------ service

resource "aws_ecs_service" "realtime" {
  name                               = "realtime"
  cluster                            = aws_ecs_cluster.main.id
  task_definition                    = aws_ecs_task_definition.realtime.arn
  desired_count                      = var.realtime_min_tasks
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60
  enable_ecs_managed_tags            = true
  propagate_tags                     = "SERVICE"
  enable_execute_command             = var.realtime_enable_execute_command
  wait_for_steady_state              = false

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = var.realtime_min_tasks
    weight            = 1
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.realtime_spot_weight > 0 ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = var.realtime_spot_weight
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  network_configuration {
    subnets          = [for subnet in aws_subnet.private : subnet.id]
    security_groups  = [aws_security_group.realtime.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.realtime.arn
    container_name   = local.realtime_container
    container_port   = local.realtime_port
  }

  lifecycle {
    # deploy-realtime.yml owns the image (task definition revisions); autoscaling owns the task count.
    ignore_changes = [task_definition, desired_count]
  }

  depends_on = [aws_lb_listener_rule.realtime, aws_iam_role_policy.realtime_execution]
}

# ------------------------------------------------------------------ autoscaling

resource "aws_appautoscaling_target" "realtime" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.realtime.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.realtime_min_tasks
  max_capacity       = var.realtime_max_tasks
}

# Primary signal: open sockets per task (emitted by observability/metrics.js as EMF every 15 s:
# namespace Classroom/Realtime, metric ActiveConnections, dimensions Environment + ServiceName).
# Scale-in is slow on purpose: every removed task makes its clients reconnect.
resource "aws_appautoscaling_policy" "realtime_connections" {
  name               = "${local.realtime_name}-connections"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.realtime.service_namespace
  resource_id        = aws_appautoscaling_target.realtime.resource_id
  scalable_dimension = aws_appautoscaling_target.realtime.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.realtime_target_connections_per_task
    scale_out_cooldown = 60
    scale_in_cooldown  = 900

    customized_metric_specification {
      metric_name = "ActiveConnections"
      namespace   = "Classroom/Realtime"
      statistic   = "Average"
      unit        = "Count"

      dimensions {
        name  = "Environment"
        value = var.environment
      }
      dimensions {
        name  = "ServiceName"
        value = "realtime"
      }
    }
  }
}

resource "aws_appautoscaling_policy" "realtime_memory" {
  name               = "${local.realtime_name}-memory"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.realtime.service_namespace
  resource_id        = aws_appautoscaling_target.realtime.resource_id
  scalable_dimension = aws_appautoscaling_target.realtime.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 70
    scale_out_cooldown = 60
    scale_in_cooldown  = 900

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "realtime_cpu" {
  name               = "${local.realtime_name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.realtime.service_namespace
  resource_id        = aws_appautoscaling_target.realtime.resource_id
  scalable_dimension = aws_appautoscaling_target.realtime.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_out_cooldown = 60
    scale_in_cooldown  = 900

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# ------------------------------------------------------------------ outputs

output "realtime_service_name" {
  description = "ECS service name (ECS_REALTIME_SERVICE in deploy-realtime.yml)."
  value       = aws_ecs_service.realtime.name
}

output "realtime_task_role_arn" {
  description = "Task role of the realtime service."
  value       = aws_iam_role.realtime_task.arn
}

output "realtime_target_group_arn" {
  description = "ALB target group of the realtime service."
  value       = aws_lb_target_group.realtime.arn
}