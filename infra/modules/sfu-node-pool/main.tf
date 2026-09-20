###############################################################################
# infra/modules/sfu-node-pool/main.tf
#
# One pool of SFU nodes in one media region.  (F1, F8)
#
# Replaces v6's ecs-sfu.tf. The correction that drives every decision here:
# there is NO load balancer on the media path. An NLB gives many nodes one
# address, and an ICE candidate that points at a shared address cannot
# identify the node that owns the transport — the candidate is simply wrong for
# every node but one. On top of that, NLB listeners are per port and capped,
# which contradicted the announced port range in the first place.
#
# So: each instance gets an Elastic IP from a pre-allocated pool, runs exactly
# one SFU task with host networking, and announces its own address. Load is
# distributed by placement (RoomPlacementService picks the least loaded node
# from the registry), not by packet routing. Health is enforced by registry
# heartbeats with a 15 s TTL, not by a target group.
#
# Each task is SFU + capture sidecar: recording RTP goes over loopback and
# never touches the network.
###############################################################################

locals {
  name = "${var.name_prefix}-sfu-${var.region}"

  # WebRtcServer ports: one UDP and one TCP per mediasoup worker,
  # MEDIASOUP_RTC_PORT_BASE + workerIndex. The security group opens exactly
  # this range and nothing else.
  rtc_port_min = var.rtc_port_base
  rtc_port_max = var.rtc_port_base + var.workers_per_node - 1
}

###############################################################################
# ECS capacity provider backed by the ASG
###############################################################################

resource "aws_ecs_capacity_provider" "this" {
  name = local.name

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.this.arn

    # Terraform owns scaling (autoscaling.tf); managed scaling would fight it
    # and, worse, would terminate instances without going through the drain.
    managed_scaling {
      status = "DISABLED"
    }

    # Never let ECS terminate an instance on its own: a terminated node drops
    # every live lesson on it. Scale-in happens only through the lifecycle
    # hook and the drain.
    managed_termination_protection = "ENABLED"
  }

  tags = var.tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = var.ecs_cluster_name
  capacity_providers = [aws_ecs_capacity_provider.this.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 1
    base              = 0
  }
}

###############################################################################
# Auto Scaling group
###############################################################################

resource "aws_autoscaling_group" "this" {
  name                = local.name
  vpc_zone_identifier = var.public_media_subnet_ids # public: nodes need their EIP

  min_size         = var.min_nodes
  max_size         = var.max_nodes
  desired_capacity = var.desired_nodes

  # The instance is only "in service" once the SFU has registered a heartbeat.
  health_check_type         = "EC2"
  health_check_grace_period = 300
  default_instance_warmup   = 180

  # Protected from scale-in: ECS managed termination protection plus this flag
  # means the ASG cannot pick a node holding a live lesson.
  protect_from_scale_in = true

  capacity_rebalance = false # Spot rebalancing would move media mid-lesson

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  # One task per instance and one instance per AZ-slot: an even spread is what
  # lets a single AZ loss cost a third of capacity rather than all of it.
  instance_maintenance_policy {
    min_healthy_percentage = 100
    max_healthy_percentage = 200
  }

  dynamic "tag" {
    for_each = merge(var.tags, {
      Name                                = local.name
      AmazonECSManaged                    = "true"
      "classroom:role"                    = "sfu"
      "classroom:region"                  = var.region
      "classroom:eip-pool"                = var.eip_pool_tag
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # A release replaces nodes one at a time, and each replacement waits for the
  # old node to drain (deploy-sfu.yml, step 5). Checkpoints make the refresh
  # observable rather than a black box.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 100
      instance_warmup        = 180
      checkpoint_percentages = [25, 50, 75, 100]
      checkpoint_delay       = 300
      standby_instances      = "Terminate"
    }

    triggers = ["launch_template", "tag"]
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity] # owned by autoscaling.tf
  }

  depends_on = [aws_launch_template.this]
}

###############################################################################
# Task definition — SFU + capture sidecar
###############################################################################

resource "aws_cloudwatch_log_group" "sfu" {
  name              = "/ecs/${var.name_prefix}/sfu/${var.region}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
  tags              = var.tags
}

resource "aws_ecs_task_definition" "sfu" {
  family       = local.name
  network_mode = "host" # the whole point: the task owns the instance's ports

  requires_compatibilities = ["EC2"]
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  # Reserve almost the whole instance: one task per host, no noisy neighbour.
  cpu    = var.task_cpu
  memory = var.task_memory

  pid_mode = "task" # sidecar and SFU share a PID namespace for loopback RTP

  container_definitions = jsonencode([
    {
      name      = "sfu"
      image     = "${var.sfu_image_repository}@${var.sfu_image_digest}"
      essential = true
      command   = ["node", "server/src/sfu.js"]

      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "SERVICE_ROLE", value = "sfu" },
        { name = "MEDIA_REGION", value = var.region },
        { name = "MEDIASOUP_WORKERS", value = tostring(var.workers_per_node) },
        { name = "MEDIASOUP_RTC_PORT_BASE", value = tostring(var.rtc_port_base) },
        { name = "MEDIASOUP_PIPE_PORT_MIN", value = tostring(var.pipe_port_min) },
        { name = "MEDIASOUP_PIPE_PORT_MAX", value = tostring(var.pipe_port_max) },
        { name = "MEDIA_PUBLIC_ADDRESS_SOURCE", value = "imds" },
        { name = "SFU_CONTROL_PORT", value = tostring(var.control_port) },
        { name = "SFU_MAX_LOAD_SCORE", value = tostring(var.max_load_score) },
        { name = "CAPTURE_SIDECAR_URL", value = "http://127.0.0.1:${var.capture_port}" },
        { name = "S3_BUCKET_RECORDINGS", value = var.recordings_bucket },
        { name = "SERVICE_NAME", value = "classroom-sfu" },
        { name = "RELEASE_SHA", value = var.release_sha },
        { name = "LOG_LEVEL", value = var.log_level },
        # No TURN variable exists in this role, by design (Appendix A #3).
      ]

      secrets = [
        { name = "REDIS_STATE_URL", valueFrom = "${var.redis_secret_arn}:state_url::" },
        { name = "SFU_CONTROL_TLS_CERT", valueFrom = "${var.control_tls_secret_arn}:cert::" },
        { name = "SFU_CONTROL_TLS_KEY", valueFrom = "${var.control_tls_secret_arn}:key::" },
        { name = "SFU_CONTROL_CA", valueFrom = "${var.control_tls_secret_arn}:ca::" },
      ]

      # mediasoup needs to open its own UDP/TCP sockets on host ports; nothing
      # else is granted.
      linuxParameters = {
        initProcessEnabled = true
        capabilities       = { drop = ["ALL"], add = ["NET_BIND_SERVICE"] }
      }

      ulimits = [
        { name = "nofile", softLimit = 65536, hardLimit = 65536 }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "curl -fsS --cacert /run/sfu/ca.pem https://127.0.0.1:${var.control_port}/healthz/sfu || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      # Long stop timeout: SIGTERM starts a drain, and a drain waits for the
      # last lesson to end. The lifecycle hook, not this value, decides how
      # long that may take; this just keeps ECS from killing it early.
      stopTimeout = 120

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.sfu.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "sfu"
          "mode"                  = "non-blocking"
        }
      }
    },
    {
      name      = "capture"
      image     = "${var.capture_image_repository}@${var.capture_image_digest}"
      essential = false # a dead recorder must not end the lesson

      environment = [
        { name = "CAPTURE_PORT", value = tostring(var.capture_port) },
        { name = "S3_BUCKET_RECORDINGS", value = var.recordings_bucket },
        { name = "AWS_REGION", value = var.region },
        { name = "SEGMENT_SECONDS", value = tostring(var.recording_segment_seconds) },
        { name = "RELEASE_SHA", value = var.release_sha },
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "curl -fsS http://127.0.0.1:${var.capture_port}/healthz || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }

      stopTimeout = 60

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.sfu.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "capture"
        }
      }
    }
  ])

  tags = var.tags
}

###############################################################################
# Service
#
# No load_balancer block. No target group. Media reaches this task directly on
# the instance's Elastic IP.
###############################################################################

resource "aws_ecs_service" "sfu" {
  name            = local.name
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.sfu.arn

  scheduling_strategy = "DAEMON" # exactly one task per instance, always

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.this.name
    weight            = 1
  }

  # DAEMON placement already guarantees one per host; the constraint documents
  # and enforces it if the strategy ever changes.
  placement_constraints {
    type = "distinctInstance"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # A rolling deploy of the SFU happens through the ASG instance refresh, not
  # by restarting tasks under live rooms.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 100

  enable_execute_command = var.enable_ecs_exec

  propagate_tags = "SERVICE"
  tags           = var.tags

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}