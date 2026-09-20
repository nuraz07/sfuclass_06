# infra/modules/sfu-node-pool/autoscaling.tf
#
# Capacity of the SFU pool:
#
#   Auto Scaling group     network-optimised instances, one per SFU task. max_size = 2 × max_nodes + 1 (blue/green
#                          switch plus one replacement). Protected from scale-in; only ECS removes empty instances.
#   ECS capacity provider  managed scaling (instances follow tasks); managed draining OFF — draining is room-aware and
#                          owned by drainSfu.js and the terminate hook.
#   Service scaling        target tracking on Classroom/Sfu LoadScore (region average of
#                          max(CPU of the busiest worker, consumers / capacity, egress / capacity), sfu-node/loadReporter.js).
#                          Scale-OUT only: an ECS scale-in would stop a task with live rooms. Capacity is reduced by
#                          deploy-sfu.yml (sizes the new colour) or by draining nodes on purpose. The idle colour sits at 0
#                          and target tracking scales proportionally to the current count, so it stays at 0.
#                          Placement (RoomPlacementService) keeps new rooms below 0.75 on every node, so scale-out has
#                          headroom before a node is full.
#
# Owner: F1 Live Classrooms + F8 Real-Time Connectivity.

resource "aws_autoscaling_group" "sfu" {
  name_prefix               = "${local.name}-"
  vpc_zone_identifier       = var.subnet_ids
  min_size                  = 0
  max_size                  = 2 * var.max_nodes + 1
  health_check_type         = "EC2"
  health_check_grace_period = 300
  default_instance_warmup   = 300
  protect_from_scale_in     = true
  capacity_rebalance        = var.spot_allowed
  wait_for_capacity_timeout = "0"

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = var.spot_allowed ? 0 : 100
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.sfu.id
        version            = "$Latest"
      }

      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  dynamic "initial_lifecycle_hook" {
    for_each = local.lifecycle_hooks
    content {
      name                  = initial_lifecycle_hook.value.name
      lifecycle_transition  = initial_lifecycle_hook.value.transition
      heartbeat_timeout     = initial_lifecycle_hook.value.heartbeat_timeout
      default_result        = initial_lifecycle_hook.value.default_result
      notification_metadata = jsonencode(initial_lifecycle_hook.value.notification_payload)
    }
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }
  tag {
    key                 = "Name"
    value               = local.name
    propagate_at_launch = true
  }
  tag {
    key                 = "MediaPool"
    value               = "sfu"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "sfu" {
  name = local.name

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.sfu.arn
    managed_termination_protection = "ENABLED"
    managed_draining               = "DISABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 3
      instance_warmup_period    = 300
    }
  }
}

resource "aws_appautoscaling_target" "sfu" {
  for_each = aws_ecs_service.sfu

  service_namespace  = "ecs"
  resource_id        = "service/${var.ecs_cluster.name}/${each.value.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 0
  max_capacity       = var.max_nodes
}

resource "aws_appautoscaling_policy" "sfu_load" {
  for_each = aws_appautoscaling_target.sfu

  name               = "${local.name}-${each.key}-load-score"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.target_load_score
    disable_scale_in   = true
    scale_out_cooldown = 300

    customized_metric_specification {
      namespace   = "Classroom/Sfu"
      metric_name = "LoadScore"
      statistic   = "Average"

      dimensions {
        name  = "Region"
        value = var.region
      }
    }
  }
}

# Pages when the active colour runs fewer healthy nodes than the floor for 10 minutes (instances failing to boot,
# Elastic IPs exhausted, AMI or image problems).
resource "aws_cloudwatch_metric_alarm" "below_min_nodes" {
  alarm_name          = "${local.name}-below-min-nodes"
  alarm_description   = "Fewer running SFU tasks than min_nodes (${var.min_nodes}) in ${var.region}. Runbook: ops/runbooks/sfu-incident.md"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 10
  threshold           = var.min_nodes
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]

  metric_query {
    id          = "running"
    expression  = "SUM(METRICS())"
    label       = "Running SFU tasks (both colours)"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = local.service_names
    content {
      id = "m_${metric_query.key}"
      metric {
        namespace   = "ECS/ContainerInsights"
        metric_name = "RunningTaskCount"
        period      = 60
        stat        = "Minimum"
        dimensions = {
          ClusterName = var.ecs_cluster.name
          ServiceName = metric_query.value
        }
      }
    }
  }
}