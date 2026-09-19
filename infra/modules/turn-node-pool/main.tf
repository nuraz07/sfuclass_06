# infra/modules/turn-node-pool/main.tf
#
# TURN nodes of one media region: coturn + agent (turn/Dockerfile, one image, two containers) as ECS on EC2 with host
# networking, exactly one task per instance.
#
#   container "coturn"      entrypoint.sh coturn   STUN/TURN on UDP+TCP 3478 and TLS 443, relay 49152-65535
#   container "turn-agent"  entrypoint.sh agent    self-probe, registry heartbeat, metrics bridge, drain, /healthz
#   volume "turn-runtime"   tmpfs shared by both (rendered config, secrets for the probe, node.json), uid 10001
#
# Two services, <service_base>-blue and <service_base>-green, with the same task definition family. Exactly one colour
# carries nodes; .github/workflows/deploy-turn.yml switches colours for every release and node refresh, draining the old
# colour by allocations. Terraform creates both (blue with min_nodes, green with 0) and then leaves image and task count
# to the workflow and to autoscaling (autoscaling.tf).
#
# Files of this module:
#   main.tf              roles, log group, task definition, services (this file)
#   launch-template.tf   instance role, AMI, launch template (IMDSv2, instance metadata tags, host tuning)
#   security-group.tf    3478/443 in from anywhere, relay ports only to and from SFU addresses
#   lifecycle-hooks.tf   launch and terminate hooks (EIP attach, allocation drain)
#   autoscaling.tf       Auto Scaling group, ECS capacity provider, scaling on LoadRatio
#
# Owner: F8 Real-Time Connectivity.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  name        = "${var.name_prefix}-turn-${var.region_short}"
  environment = element(split("-", var.name_prefix), length(split("-", var.name_prefix)) - 1)
  turn_env    = lookup({ prod = "production", staging = "staging", dev = "development" }, local.environment, "production")
  partition   = data.aws_partition.current.partition
  account_id  = data.aws_caller_identity.current.account_id

  # <account>.dkr.ecr.<region>.amazonaws.com/<repository>[:tag|@digest]
  image_parts    = regex("^([0-9]+)\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com/([^:@]+)", var.image)
  repository_arn = "arn:${local.partition}:ecr:${local.image_parts[1]}:${local.image_parts[0]}:repository/${local.image_parts[2]}"
  image_tag      = try(regex(":([^:@/]+)$", var.image)[0], "digest")

  colours          = ["blue", "green"]
  service_names    = { for c in local.colours : c => "${var.service_base}-${c}" }
  agent_port       = 8080
  prometheus_port  = 9641
  runtime_dir      = "/run/turn"
  container_uid    = 10001
  stop_timeout_sec = 120
}

# ------------------------------------------------------------------ logs

resource "aws_cloudwatch_log_group" "turn" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

# ------------------------------------------------------------------ task roles

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:*"]
    }
  }
}

# Execution role: pull the image, write logs, inject REDIS_STATE_URL into the agent.
resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "PullImage"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [local.repository_arn]
  }
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.turn.arn}:*"]
  }
  statement {
    sid       = "InjectRedisUrl"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.secret_arns.redis_state_url]
  }
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# Task role: the bootstrap reads the TURN secret ring and the TLS certificate itself (curl with SigV4, all version
# stages), the agent completes lifecycle hooks after draining.
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid       = "TurnSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.secret_arns.turn_shared_secret, var.secret_arns.turn_tls]
  }
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_kms_key_arn]
  }
  statement {
    sid       = "CompleteOwnLifecycleHooks"
    actions   = ["autoscaling:CompleteLifecycleAction", "autoscaling:RecordLifecycleActionHeartbeat"]
    resources = [aws_autoscaling_group.turn.arn]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ------------------------------------------------------------------ task definition

locals {
  common_environment = {
    TURN_ENV           = local.turn_env
    TURN_REALM         = var.realm
    TURN_RUNTIME_DIR   = local.runtime_dir
    RELEASE_SHA        = local.image_tag
    NODE_ENV           = "production"
    TURN_AGENT_PORT    = tostring(local.agent_port)
    TURN_PROBE_PEER_IP = var.probe_peer_ip
  }

  coturn_environment = merge(local.common_environment, {
    TURN_ADDRESS_SOURCE   = "imds"
    TURN_SECRET_SOURCE    = "secretsmanager"
    TURN_TLS_SOURCE       = "secretsmanager"
    TURN_SECRET_ARN       = var.secret_arns.turn_shared_secret
    TURN_TLS_SECRET_ARN   = var.secret_arns.turn_tls
    TURN_REGION           = var.region
    TURN_LISTEN_PORT      = "3478"
    TURN_TLS_PORT         = "443"
    TURN_RELAY_MIN_PORT   = tostring(var.relay_port_range.min)
    TURN_RELAY_MAX_PORT   = tostring(var.relay_port_range.max)
    TURN_USER_QUOTA       = tostring(var.user_quota)
    TURN_TOTAL_QUOTA      = tostring(var.total_quota)
    TURN_MAX_BPS          = tostring(var.max_bps)
    TURN_BPS_CAPACITY     = tostring(var.bps_capacity)
    TURN_CAPACITY_MBPS    = tostring(var.capacity_mbps)
    TURN_PROMETHEUS_PORT  = tostring(local.prometheus_port)
    TURN_BOOTSTRAP_WAIT_S = "300"
  })

  agent_environment = merge(local.common_environment, {
    REDIS_CLUSTER         = var.redis_cluster_mode ? "true" : "false"
    TURN_DRAIN_TIMEOUT_MS = tostring(var.drain_timeout_minutes * 60000)
  })

  log_options = {
    awslogs-group   = aws_cloudwatch_log_group.turn.name
    awslogs-region  = var.region
    mode            = "non-blocking"
    max-buffer-size = "4m"
  }
  runtime_mount = [{ sourceVolume = "turn-runtime", containerPath = local.runtime_dir, readOnly = false }]
}

resource "aws_ecs_task_definition" "turn" {
  family                   = local.name
  requires_compatibilities = ["EC2"]
  network_mode             = "host"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # Shared tmpfs, owned by the image's uid 10001 (turn/Dockerfile runtime contract).
  volume {
    name = "turn-runtime"

    docker_volume_configuration {
      scope  = "task"
      driver = "local"
      driver_opts = {
        type   = "tmpfs"
        device = "tmpfs"
        o      = "size=16m,uid=${local.container_uid},gid=${local.container_uid},mode=0700"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name                   = "coturn"
      image                  = var.image
      essential              = true
      command                = ["coturn"]
      user                   = "${local.container_uid}:${local.container_uid}"
      readonlyRootFilesystem = true
      memoryReservation      = 512
      stopTimeout            = local.stop_timeout_sec
      environment            = [for k in sort(keys(local.coturn_environment)) : { name = k, value = local.coturn_environment[k] }]
      mountPoints            = local.runtime_mount
      ulimits                = [{ name = "nofile", softLimit = 1048576, hardLimit = 1048576 }]
      # Binding 443 as uid 10001 uses the file capability on turnserver: keep NET_BIND_SERVICE, drop the rest.
      # dockerSecurityOptions must NOT contain no-new-privileges (it would disable file capabilities).
      linuxParameters = {
        capabilities = { add = ["NET_BIND_SERVICE"], drop = ["ALL"] }
      }
      logConfiguration = { logDriver = "awslogs", options = merge(local.log_options, { awslogs-stream-prefix = "coturn" }) }
    },
    {
      name                   = "turn-agent"
      image                  = var.image
      essential              = true
      command                = ["agent"]
      user                   = "${local.container_uid}:${local.container_uid}"
      readonlyRootFilesystem = true
      memoryReservation      = 128
      stopTimeout            = local.stop_timeout_sec
      dependsOn              = [{ containerName = "coturn", condition = "START" }]
      environment            = [for k in sort(keys(local.agent_environment)) : { name = k, value = local.agent_environment[k] }]
      secrets                = [{ name = "REDIS_STATE_URL", valueFrom = var.secret_arns.redis_state_url }]
      mountPoints            = local.runtime_mount
      linuxParameters        = { capabilities = { drop = ["ALL"] } }
      healthCheck = {
        # The agent is healthy while its self-probe (STUN + TURN allocation over UDP and TLS) passes.
        command     = ["CMD", "curl", "-fsS", "--max-time", "3", "http://127.0.0.1:${local.agent_port}/healthz"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 300 # bootstrap waits up to 300 s for the Elastic IP
      }
      logConfiguration = { logDriver = "awslogs", options = merge(local.log_options, { awslogs-stream-prefix = "agent" }) }
    },
  ])
}

# ------------------------------------------------------------------ services (blue / green)

# Services must not be created before the capacity provider is attached to the cluster (root module).
resource "terraform_data" "capacity_provider_ready" {
  input = var.capacity_provider_association
}

resource "aws_ecs_service" "turn" {
  for_each = local.service_names

  name                               = each.value
  cluster                            = var.ecs_cluster.arn
  task_definition                    = aws_ecs_task_definition.turn.arn
  desired_count                      = each.key == "blue" ? var.min_nodes : 0
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_ecs_managed_tags            = true
  propagate_tags                     = "SERVICE"
  wait_for_steady_state              = false

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.turn.name
    weight            = 1
    base              = 0
  }

  # Host networking: never two TURN tasks on one instance, spread over AZs, only on TURN instances.
  placement_constraints {
    type = "distinctInstance"
  }
  placement_constraints {
    type       = "memberOf"
    expression = "attribute:media-pool == turn"
  }
  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    # deploy-turn.yml owns task definitions and colour sizes; autoscaling adjusts the active colour.
    ignore_changes = [task_definition, desired_count]
  }

  tags = {
    Colour = each.key
  }

  depends_on = [terraform_data.capacity_provider_ready, aws_iam_role_policy.execution, aws_iam_role_policy.task]
}