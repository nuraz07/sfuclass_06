###############################################################################
# infra/core/ecs-api.tf
#
# The api service. Nothing else.  (F7)
#
# v6 -> v7 correction: v6 defined the realtime service inside this file while
# describing it as a separate service. Ownership and scaling then contradicted
# each other — one task definition, one scaling policy, two very different
# workloads. realtime now lives in ecs-realtime.tf with its own service,
# scaling signal and deploy workflow. Both run the same image
# (server/Dockerfile.api); only SERVICE_ROLE and the command differ.
#
# api is stateless HTTP on Fargate: no sockets, no media, no queue consumers.
# That is what makes it safe to roll it back at any moment without touching a
# live lesson.
###############################################################################

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name_prefix}/api"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn

  tags = local.tags
}

###############################################################################
# Task definition
###############################################################################

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.api_task_cpu
  memory                   = var.api_task_memory

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.api_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # Graviton: same throughput, lower cost
  }

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${aws_ecr_repository.api.repository_url}@${var.api_image_digest}"
      essential = true

      # Build once, promote the same digest. A tag here would let staging and
      # production diverge silently.
      command = ["node", "server/src/server.js"]

      portMappings = [
        { containerPort = 8080, protocol = "tcp", name = "http" }
      ]

      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "SERVICE_ROLE", value = "api" },
        { name = "PORT", value = "8080" },
        { name = "APP_URL", value = "https://app.${var.domain_name}" },
        { name = "API_URL", value = "https://api.${var.domain_name}" },
        { name = "ALLOWED_ORIGINS", value = join(",", var.allowed_origins) },
        { name = "TRUST_PROXY", value = "1" },
        { name = "SERVICE_NAME", value = "classroom-api" },
        { name = "RELEASE_SHA", value = var.release_sha },
        { name = "LOG_LEVEL", value = var.log_level },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4318" },
        { name = "ICE_RTC_DOMAIN", value = var.rtc_domain },
        { name = "AWS_REGION", value = var.region },
      ]

      # Secrets Manager references only — never a literal, never an image layer.
      secrets = [
        { name = "DATABASE_URL", valueFrom = "${aws_secretsmanager_secret.database_url.arn}:url::" },
        { name = "DATABASE_READ_URL", valueFrom = "${aws_secretsmanager_secret.database_url.arn}:read_url::" },
        { name = "REDIS_STATE_URL", valueFrom = "${aws_secretsmanager_secret.redis.arn}:state_url::" },
        { name = "REDIS_CACHE_URL", valueFrom = "${aws_secretsmanager_secret.redis.arn}:cache_url::" },
        { name = "JWT_PRIVATE_KEY", valueFrom = "${aws_secretsmanager_secret.jwt.arn}:private_key::" },
        { name = "JWT_PUBLIC_KEY", valueFrom = "${aws_secretsmanager_secret.jwt.arn}:public_key::" },
        { name = "COOKIE_SECRET", valueFrom = "${aws_secretsmanager_secret.jwt.arn}:cookie_secret::" },
        { name = "CDN_PRIVATE_KEY", valueFrom = aws_secretsmanager_secret.cdn_signing.arn },
        { name = "STRIPE_SECRET_KEY", valueFrom = "${aws_secretsmanager_secret.stripe.arn}:secret_key::" },
        { name = "STRIPE_WEBHOOK_SECRET", valueFrom = "${aws_secretsmanager_secret.stripe.arn}:webhook_secret::" },
        # TURN signing secret ring and the ICE pseudonym pepper: api and
        # realtime mint credentials, the SFU never sees either.
        { name = "TURN_SHARED_SECRET", valueFrom = aws_secretsmanager_secret.turn_secret_ring.arn },
        { name = "ICE_OPAQUE_ID_PEPPER", valueFrom = aws_secretsmanager_secret.ice_pepper.arn },
        { name = "INTERNAL_OPS_TOKEN", valueFrom = aws_secretsmanager_secret.internal_ops_token.arn },
      ]

      # Nothing durable is written to disk; /tmp is the only writable path.
      readonlyRootFilesystem = true
      mountPoints = [
        { sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }
      ]

      linuxParameters = {
        initProcessEnabled = true
        capabilities       = { drop = ["ALL"] }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:8080/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
        interval    = 15
        timeout     = 3
        retries     = 3
        startPeriod = 20
      }

      # SIGTERM -> readiness off -> drain -> close pools. server.js budgets
      # 25 s; the task-level stopTimeout below gives it 30.
      stopTimeout = 30

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "api"
          "mode"                  = "non-blocking"
          "max-buffer-size"       = "4m"
        }
      }
    },
    {
      name      = "otel"
      image     = var.otel_collector_image
      essential = false

      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "OTEL_RESOURCE_ATTRIBUTES", value = "service.name=classroom-api,service.version=${var.release_sha}" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "otel"
        }
      }
    }
  ])

  volume {
    name = "tmp"
  }

  tags = local.tags
}

###############################################################################
# Service
###############################################################################

resource "aws_ecs_service" "api" {
  name            = "${local.name_prefix}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_desired_count

  # Spread across all three AZs before scaling within one.
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = var.api_min_count
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.api_spot_weight > 0 ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = var.api_spot_weight
    }
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }

  # A task must pass /readyz before it counts; the ALB does the actual check.
  health_check_grace_period_seconds = 60

  deployment_controller {
    type = "ECS"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # 200/100 keeps full capacity during a deploy: a rolling release never
  # reduces headroom below the current desired count.
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  enable_execute_command = var.enable_ecs_exec # break-glass only, audited

  propagate_tags = "SERVICE"
  tags           = local.tags

  lifecycle {
    # autoscaling.tf owns desired_count after the first apply.
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.https]
}

###############################################################################
# Security group
###############################################################################

resource "aws_security_group" "api" {
  name        = "${local.name_prefix}-api"
  description = "api tasks: ingress from the ALB only"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name_prefix}-api" })
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "HTTP from the load balancer"
}

resource "aws_vpc_security_group_egress_rule" "api_all" {
  security_group_id = aws_security_group.api.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Stripe, APNs, SES, ECR, Secrets Manager (via endpoints where available)"
}