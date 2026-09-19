# infra/modules/turn-node-pool/autoscaling.tf
#
# Capacity of the TURN pool:
#
#   Auto Scaling group     network-optimised instances (mixed-instances policy over var.instance_types), one per TURN
#                          task. max_size = 2 × max_nodes + 1: during a blue/green switch both colours hold nodes.
#                          Instances are protected from scale-in; only ECS (capacity provider) removes empty ones.
#   ECS capacity provider  managed scaling: instances follow the number of TURN tasks (one per host).
#                          Managed draining is OFF: draining is allocation-aware and owned by the agent + terminate hook.
#   Service scaling        target tracking on Classroom/Turn LoadRatio (region average of
#                          max(allocations / total_quota, relayed Mbit/s / capacity_mbps), emitted by the agent).
#                          Scale-OUT only: ECS scale-in would stop a task with live relay allocations. Capacity is
#                          reduced by deploy-turn.yml, which sizes the new colour, or by draining nodes on purpose
#                          (ops/runbooks/turn-incident.md). Both colours carry the policy; the idle colour sits at 0 and
#                          target tracking scales proportionally to the current count, so it stays at 0.
#
# Owner: F8 Real-Time Connectivity.

resource "aws_autoscaling_group" "turn" {
  name_prefix               = "${local.name}-"
  vpc_zone_identifier       = var.subnet_ids
  min_size                  = 0
  max_size                  = 2 * var.max_nodes + 1
  health_check_type         = "EC2"
  health_check_grace_period = 300
  default_instance_warmup   = 300
  protect_from_scale_in     = true # required by managed termination protection
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
        launch_template_id = aws_launch_template.turn.id
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
    value               = "turn"
    propagate_at_launch = true
  }

  lifecycle {
    # ECS managed scaling owns the desired capacity.
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "turn" {
  name = local.name

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.turn.arn
    managed_termination_protection = "ENABLED"
    managed_draining               = "DISABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100 # one task per instance: no idle instances
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 3
      instance_warmup_period    = 300
    }
  }
}

# ------------------------------------------------------------------ service scaling (scale-out only)

resource "aws_appautoscaling_target" "turn" {
  for_each = aws_ecs_service.turn

  service_namespace  = "ecs"
  resource_id        = "service/${var.ecs_cluster.name}/${each.value.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 0
  max_capacity       = var.max_nodes
}

resource "aws_appautoscaling_policy" "turn_load" {
  for_each = aws_appautoscaling_target.turn

  name               = "${local.name}-${each.key}-load-ratio"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.target_load_ratio
    disable_scale_in   = true
    scale_out_cooldown = 300

    customized_metric_specification {
      namespace   = "Classroom/Turn"
      metric_name = "LoadRatio"
      statistic   = "Average"

      dimensions {
        name  = "Region"
        value = var.region
      }
    }
  }
}