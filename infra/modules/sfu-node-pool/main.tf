# infra/modules/sfu-node-pool/main.tf
#
# SFU nodes of one media region (replaces the v6 file infra/ecs-sfu.tf). Each node is one EC2 instance with host
# networking, its own Elastic IP from the pool, and exactly one task:
#
#   container "sfu"       server/src/sfu.js — mediasoup workers, one WebRtcServer (UDP + TCP port) per worker,
#                         control RPC (mTLS) on the private IP, registry heartbeat, drain watcher
#   container "capture"   server/Dockerfile.capture — receives recording RTP over loopback, writes segments to the
#                         shared scratch volume; not essential: a capture failure ends recordings, never lessons
#   volume "capture-scratch"   task-scoped disk volume shared by both (segments until uploaded)
#
# No load balancer anywhere on the media path: clients reach the node's Elastic IP directly (ICE candidates), the
# realtime service reaches the control port over the Transit Gateway, and TURN nodes relay to the Elastic IP.
#
# Two services, <service_base>-blue and <service_base>-green, like the TURN pool: an SFU node can only be replaced
# after its rooms have ended, which a rolling ECS deployment cannot wait for. deploy-sfu.yml switches colours and
# drains the old one (drain flag → no new rooms → rooms end → scale to 0). Terraform creates both and then leaves
# images and task counts to the workflow and to autoscaling.
#
# Owner: F1 Live Classrooms + F8 Real-Time Connectivity.

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
  name       = "${var.name_prefix}-sfu-${var.region_short}"
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  # <account>.dkr.ecr.<region>.amazonaws.com/<repository>[:tag|@digest]
  image_parts = [
    for image in [var.images.sfu, var.images.capture] :
    regex("^([0-9]+)\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com/([^:@]+)", image)
  ]
  repository_arns = distinct([for p in local.image_parts : "arn:${local.partition}:ecr:${p[1]}:${p[0]}:repository/${p[2]}"])
  image_tag       = try(regex(":([^:@/]+)$", var.images.sfu)[0], "digest")

  rtc_port_max     = var.rtc_port_base + var.workers - 1
  colours          = ["blue", "green"]
  service_names    = { for c in local.colours : c => "${var.service_base}-${c}" }
  container_uid    = 1000 # sfu and capture share uid/gid 1000 so both can read and delete segments
  stop_timeout_sec = 120
  recordings_name  = var.recordings_bucket_arn == null ? "" : element(split(":", var.recordings_bucket_arn), 5)
}

# ------------------------------------------------------------------ logs

resource "aws_cloudwatch_log_group" "sfu" {
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

# Execution role: pull both images, write logs, inject the control-plane certificates and the Redis URL.
resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "PullImages"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = local.repository_arns
  }
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.sfu.arn}:*"]
  }
  statement {
    sid       = "InjectSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.secret_arns.redis_state_url, var.secret_arns.control_tls, var.secret_arns.control_ca]
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

# Task role: drainSfu.js completes the node's terminate hook after its rooms ended; recordingPipeline.js uploads
# segments.
resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid       = "CompleteOwnLifecycleHooks"
    actions   = ["autoscaling:CompleteLifecycleAction", "autoscaling:RecordLifecycleActionHeartbeat"]
    resources = [aws_autoscaling_group.sfu.arn]
  }

  dynamic "statement" {
    for_each = var.recordings_bucket_arn == null ? [] : [1]
    content {
      sid       = "UploadRecordingSegments"
      actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
      resources = ["${var.recordings_bucket_arn}/recordings/segments/*"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ------------------------------------------------------------------ task definition

locals {
  sfu_environment = merge({
    NODE_ENV                    = "production"
    SERVICE_ROLE                = "sfu"
    SERVICE_NAME                = "sfu"
    LOG_LEVEL                   = "info"
    RELEASE_SHA                 = local.image_tag
    MEDIA_REGION                = var.region
    MEDIA_PUBLIC_ADDRESS_SOURCE = "imds"
    MEDIASOUP_WORKERS           = tostring(var.workers)
    MEDIASOUP_RTC_PORT_BASE     = tostring(var.rtc_port_base)
    MEDIASOUP_PIPE_PORT_MIN     = tostring(var.pipe_port_range.min)
    MEDIASOUP_PIPE_PORT_MAX     = tostring(var.pipe_port_range.max)
    SFU_CONTROL_PORT            = tostring(var.control_port)
    SFU_MAX_LOAD_SCORE          = tostring(var.max_load_score)
    SFU_CONSUMERS_PER_WORKER    = tostring(var.consumers_per_worker)
    SFU_EGRESS_CAPACITY_MBPS    = tostring(var.egress_capacity_mbps)
    SFU_DRAIN_TIMEOUT_MS        = tostring(var.drain_timeout_minutes * 60000)
    SFU_SIGTERM_GRACE_MS        = "25000"
    REDIS_TLS                   = "true"
    REDIS_CLUSTER               = var.redis_cluster_mode ? "true" : "false"
    CAPTURE_AGENT_URL           = "http://127.0.0.1:7460"
    CAPTURE_SCRATCH_DIR         = "/scratch"
    CAPTURE_RTP_PORT_MIN        = tostring(var.capture_rtp_port_range.min)
    CAPTURE_RTP_PORT_MAX        = tostring(var.capture_rtp_port_range.max)
    }, var.recordings_bucket_arn == null ? {} : {
    S3_BUCKET_RECORDINGS = local.recordings_name
  })

  sfu_secrets = {
    REDIS_STATE_URL      = var.secret_arns.redis_state_url
    SFU_CONTROL_TLS_CERT = "${var.secret_arns.control_tls}:cert::"
    SFU_CONTROL_TLS_KEY  = "${var.secret_arns.control_tls}:key::"
    SFU_CONTROL_CA       = var.secret_arns.control_ca
  }

  capture_environment = {
    CAPTURE_LISTEN_PORT     = "7460"
    CAPTURE_SCRATCH_DIR     = "/scratch"
    CAPTURE_RTP_PORT_MIN    = tostring(var.capture_rtp_port_range.min)
    CAPTURE_RTP_PORT_MAX    = tostring(var.capture_rtp_port_range.max)
    CAPTURE_MAX_SESSIONS    = "32"
    CAPTURE_SEGMENT_SECONDS = "6"
    CAPTURE_STOP_TIMEOUT_MS = "10000"
  }

  log_options = {
    awslogs-group   = aws_cloudwatch_log_group.sfu.name
    awslogs-region  = var.region
    mode            = "non-blocking"
    max-buffer-size = "4m"
  }
  scratch_mount = [{ sourceVolume = "capture-scratch", containerPath = "/scratch", readOnly = false }]

  # Health: GET https://<private IP>:<control port>/healthz/sfu (served without client certificate; the node's own
  # certificate is not verified here — this only asks whether the process answers healthily).
  sfu_health_command = join("", [
    "const i=Object.values(require('os').networkInterfaces()).flat().find(x=>x&&x.family==='IPv4'&&!x.internal);",
    "require('https').get({host:i.address,port:${var.control_port},path:'/healthz/sfu',rejectUnauthorized:false,timeout:3000},",
    "r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1)).on('timeout',()=>process.exit(1));",
  ])
}

resource "aws_ecs_task_definition" "sfu" {
  family                   = local.name
  requires_compatibilities = ["EC2"]
  network_mode             = "host"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  volume {
    name = "capture-scratch"

    docker_volume_configuration {
      scope  = "task"
      driver = "local"
    }
  }

  container_definitions = jsonencode([
    {
      name                   = "sfu"
      image                  = var.images.sfu
      essential              = true
      command                = ["node", "--import", "./src/observability/tracing.js", "./src/sfu.js"]
      user                   = "${local.container_uid}:${local.container_uid}"
      readonlyRootFilesystem = true
      memoryReservation      = 1024
      stopTimeout            = local.stop_timeout_sec
      environment            = [for k in sort(keys(local.sfu_environment)) : { name = k, value = local.sfu_environment[k] }]
      secrets                = [for k in sort(keys(local.sfu_secrets)) : { name = k, valueFrom = local.sfu_secrets[k] }]
      mountPoints            = local.scratch_mount
      ulimits                = [{ name = "nofile", softLimit = 1048576, hardLimit = 1048576 }]
      linuxParameters        = { capabilities = { drop = ["ALL"] }, initProcessEnabled = true }
      healthCheck = {
        command     = ["CMD", "node", "-e", local.sfu_health_command]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 300 # waits up to 300 s for the Elastic IP before the control server listens
      }
      logConfiguration = { logDriver = "awslogs", options = merge(local.log_options, { awslogs-stream-prefix = "sfu" }) }
    },
    {
      name                   = "capture"
      image                  = var.images.capture
      essential              = false
      user                   = "${local.container_uid}:${local.container_uid}"
      readonlyRootFilesystem = true
      memoryReservation      = 256
      stopTimeout            = 30
      environment            = [for k in sort(keys(local.capture_environment)) : { name = k, value = local.capture_environment[k] }]
      mountPoints            = local.scratch_mount
      linuxParameters        = { capabilities = { drop = ["ALL"] } }
      healthCheck = {
        command     = ["CMD", "node", "/app/healthcheck.mjs"]
        interval    = 15
        timeout     = 3
        retries     = 3
        startPeriod = 10
      }
      logConfiguration = { logDriver = "awslogs", options = merge(local.log_options, { awslogs-stream-prefix = "capture" }) }
    },
  ])
}

# ------------------------------------------------------------------ services (blue / green)

resource "terraform_data" "capacity_provider_ready" {
  input = var.capacity_provider_association
}

resource "aws_ecs_service" "sfu" {
  for_each = local.service_names

  name                               = each.value
  cluster                            = var.ecs_cluster.arn
  task_definition                    = aws_ecs_task_definition.sfu.arn
  desired_count                      = each.key == "blue" ? var.min_nodes : 0
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_ecs_managed_tags            = true
  propagate_tags                     = "SERVICE"
  wait_for_steady_state              = false

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.sfu.name
    weight            = 1
    base              = 0
  }

  placement_constraints {
    type = "distinctInstance"
  }
  placement_constraints {
    type       = "memberOf"
    expression = "attribute:media-pool == sfu"
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
    # deploy-sfu.yml owns task definitions and colour sizes; autoscaling adjusts the active colour.
    ignore_changes = [task_definition, desired_count]
  }

  tags = {
    Colour = each.key
  }

  depends_on = [terraform_data.capacity_provider_ready, aws_iam_role_policy.execution, aws_iam_role_policy.task]
}