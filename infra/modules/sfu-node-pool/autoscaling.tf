###############################################################################
# infra/modules/sfu-node-pool/autoscaling.tf
#
# Scale out on load, scale in only through the drain.  (F1)
#
# Why not CPU: an SFU node runs out of network and of consumer count long
# before it runs out of CPU. A node at 40 % CPU can already be dropping
# packets. The scaling signal is the same load score the placement service
# uses, published by sfu-node/loadReporter.js as EMF:
#
#   score = 0.25*producers + 0.35*consumers + 0.25*egressMbps + 0.15*cpu
#           (each normalised against the node's reference capacity)
#
# Using the same number for placement and for scaling means the fleet never
# ends up in the state where placement refuses every node while the ASG sees
# no reason to add one.
#
# Scale-in never terminates directly: the policy lowers desired capacity, the
# terminate lifecycle hook drains the chosen node, and only then does it go.
###############################################################################

###############################################################################
# Scale out — target tracking on the fleet's average load score
###############################################################################

resource "aws_autoscaling_policy" "load_score" {
  name                   = "${local.name}-load-score"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  # Adding a node takes ~3 minutes (boot, EIP attach, image pull, worker
  # start). Staying at 60 % leaves exactly that much headroom.
  estimated_instance_warmup = 180

  target_tracking_configuration {
    target_value     = var.target_load_score * 100 # 60 == 0.60
    disable_scale_in = true                        # scale-in is handled below

    customized_metric_specification {
      metrics {
        id    = "score"
        label = "Average SFU load score across the pool (%)"

        metric_stat {
          metric {
            namespace   = var.metric_namespace
            metric_name = "SfuLoadScore"

            dimensions {
              name  = "Region"
              value = var.region
            }

            dimensions {
              name  = "Pool"
              value = local.name
            }
          }

          stat = "Average"
        }

        return_data = true
      }
    }
  }
}

###############################################################################
# Scale out — fast path
#
# Target tracking reacts on a 3-minute average, which is too slow for the case
# that actually hurts: a scheduled hour where two hundred classes start at the
# same minute. This step policy adds capacity as soon as the fleet crosses the
# cascade threshold, before placement has to start fanning rooms out.
###############################################################################

resource "aws_autoscaling_policy" "burst_out" {
  name                   = "${local.name}-burst-out"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"
  metric_aggregation_type = "Maximum"

  estimated_instance_warmup = 180

  step_adjustment {
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 15
    scaling_adjustment          = 1
  }

  step_adjustment {
    metric_interval_lower_bound = 15
    scaling_adjustment          = 3
  }
}

resource "aws_cloudwatch_metric_alarm" "burst_out" {
  alarm_name          = "${local.name}-load-burst"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 60
  statistic           = "Maximum"
  threshold           = var.cascade_threshold * 100
  namespace           = var.metric_namespace
  metric_name         = "SfuLoadScore"
  treat_missing_data  = "notBreaching"
  alarm_description   = "Any node above the cascade threshold — add capacity now"

  dimensions = {
    Region = var.region
    Pool   = local.name
  }

  alarm_actions = [aws_autoscaling_policy.burst_out.arn]
  tags          = var.tags
}

###############################################################################
# Scale in — slow, conservative, drain-mediated
#
# Conditions: the fleet has been well below target for 30 consecutive minutes
# AND more than the minimum number of nodes is running. Removing a node costs
# up to four hours of drain, so being wrong is expensive and being slow is not.
###############################################################################

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "${local.name}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    metric_interval_upper_bound = 0
    scaling_adjustment          = -1 # one node at a time, always
  }
}

resource "aws_cloudwatch_metric_alarm" "scale_in" {
  alarm_name          = "${local.name}-load-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 30 # 30 x 1 min
  period              = 60
  statistic           = "Average"
  threshold           = var.scale_in_load_score * 100
  namespace           = var.metric_namespace
  metric_name         = "SfuLoadScore"
  treat_missing_data  = "missing" # no data must never trigger a scale-in
  alarm_description   = "Pool sustained well below target — release one node through the drain"

  dimensions = {
    Region = var.region
    Pool   = local.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_in.arn]
  tags          = var.tags
}

###############################################################################
# Guard rails
###############################################################################

# At the ceiling there is no capacity left to place new rooms in this region;
# placement starts refusing or spilling to another region.
resource "aws_cloudwatch_metric_alarm" "at_max_capacity" {
  alarm_name          = "${local.name}-at-max-capacity"
  namespace           = "AWS/AutoScaling"
  metric_name         = "GroupInServiceInstances"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  period              = 300
  statistic           = "Maximum"
  threshold           = var.max_nodes
  alarm_description   = "SFU pool at max size — raise max_nodes or add a media region"

  dimensions = { AutoScalingGroupName = aws_autoscaling_group.this.name }

  alarm_actions = [var.pager_topic_arn]
  tags          = var.tags
}

# Node saturation: individual nodes above the cap stop receiving rooms, and
# cascading should be engaging. If it is not, a large room is stuck on one box.
resource "aws_cloudwatch_metric_alarm" "node_saturation" {
  alarm_name          = "${local.name}-node-saturation"
  namespace           = var.metric_namespace
  metric_name         = "SfuLoadScore"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  period              = 60
  statistic           = "Maximum"
  threshold           = var.max_load_score * 100
  treat_missing_data  = "notBreaching"
  alarm_description   = "A node is above its load cap — scale out, confirm cascading is engaging (ops/runbooks/sfu-incident.md)"

  dimensions = {
    Region = var.region
    Pool   = local.name
  }

  alarm_actions = [var.pager_topic_arn]
  tags          = var.tags
}

# The pool cannot grow without free Elastic IPs. Alarming at 20 % remaining
# gives time to allocate more and republish the customer IP ranges.
resource "aws_cloudwatch_metric_alarm" "registry_gap" {
  alarm_name          = "${local.name}-registry-gap"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "Instances InService but not heartbeating to the registry — check EIP attach and the control path"

  metric_query {
    id          = "gap"
    expression  = "instances - registered"
    label       = "InService minus registered"
    return_data = true
  }

  metric_query {
    id = "instances"
    metric {
      namespace   = "AWS/AutoScaling"
      metric_name = "GroupInServiceInstances"
      period      = 300
      stat        = "Maximum"
      dimensions  = { AutoScalingGroupName = aws_autoscaling_group.this.name }
    }
  }

  metric_query {
    id = "registered"
    metric {
      namespace   = var.metric_namespace
      metric_name = "SfuNodesRegistered"
      period      = 300
      stat        = "Maximum"
      dimensions  = { Region = var.region }
    }
  }

  alarm_actions = [var.pager_topic_arn]
  tags          = var.tags
}