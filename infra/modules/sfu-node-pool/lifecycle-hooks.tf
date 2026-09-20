###############################################################################
# infra/modules/sfu-node-pool/lifecycle-hooks.tf
#
# Launch: attach an Elastic IP before the node serves anything.
# Terminate: drain every room before the node goes away.       (F1, F8)
#
# These two hooks are what make "no load balancer on the media path" workable.
# Without the launch hook a node has no stable address to announce; without the
# terminate hook a scale-in or a release kills live lessons.
#
# Both hooks are handled by functions/node-lifecycle (shared with
# turn-node-pool), wired by modules/node-lifecycle. The heartbeat TTL in the
# registry is 15 s, so anything the Lambda does must be visible to placement
# within that window.
###############################################################################

###############################################################################
# Launch — the node is not InService until it has an address
#
# Sequence performed by the Lambda:
#   1. take a free EIP from the region's pre-allocated pool (eip-pool.tf),
#      tagged for this pool, and associate it;
#   2. add the address to the sfu-public managed prefix list, so the TURN
#      fleet is allowed to relay to it;
#   3. trigger publish-ip-ranges so the customer-facing allowlist document
#      stays accurate;
#   4. complete the hook.
#
# If the Lambda fails, the heartbeat timeout (below) abandons the instance:
# a node without an EIP would announce a candidate nobody can reach, which is
# worse than no node at all.
###############################################################################

resource "aws_autoscaling_lifecycle_hook" "launch" {
  name                   = "${local.name}-launch"
  autoscaling_group_name = aws_autoscaling_group.this.name

  lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
  default_result       = "ABANDON"
  heartbeat_timeout    = var.launch_hook_timeout_seconds # 300

  notification_metadata = jsonencode({
    role         = "sfu"
    region       = var.region
    eipPoolTag   = var.eip_pool_tag
    prefixListId = var.sfu_prefix_list_id
    namePrefix   = var.name_prefix
  })
}

###############################################################################
# Terminate — drain, then leave
#
# Sequence performed by the Lambda and the node itself:
#   1. Lambda writes media:drain:<nodeId> to the state Redis cluster.
#      RoomPlacementService skips draining nodes immediately, so no new room
#      lands here. This is the "placement freeze" step in the incident runbook.
#   2. Lambda sends SIGTERM to the task; lifecycle/drainSfu.js deregisters the
#      node from the SFU registry (heartbeat stops within 5 s) and stops
#      accepting new transports on existing rooms.
#   3. Live rooms keep running. The node waits until every room is empty, or
#      until the drain timeout expires — whichever comes first.
#   4. Recording sessions are finalised through recordingPipeline.drain(), so
#      their segments get muxed even though the node is going away.
#   5. Lambda releases the EIP back to the pool, removes it from the
#      sfu-public prefix list, and completes the hook.
#
# The timeout is the maximum lesson length plus margin. A node that still
# holds a room when it expires is terminated anyway: at that point the room is
# almost certainly stuck rather than in use, and IceRecovery re-joins the
# affected clients onto a healthy node. This is the one visible failure mode
# in the architecture and it is documented as such (§12.2).
###############################################################################

resource "aws_autoscaling_lifecycle_hook" "terminate" {
  name                   = "${local.name}-terminate"
  autoscaling_group_name = aws_autoscaling_group.this.name

  lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
  default_result       = "CONTINUE" # never strand an instance in Terminating:Wait
  heartbeat_timeout    = var.drain_timeout_seconds # 4 h + margin

  notification_metadata = jsonencode({
    role             = "sfu"
    region           = var.region
    eipPoolTag       = var.eip_pool_tag
    prefixListId     = var.sfu_prefix_list_id
    drainKeyPrefix   = "media:drain:"
    registryKeyGlob  = "media:sfu:${var.region}:*"
    maxDrainSeconds  = var.drain_timeout_seconds
  })
}

###############################################################################
# Events
#
# The Lambda is subscribed through modules/node-lifecycle, which owns the
# EventBridge rules, the DLQ and the permissions. This rule is scoped to this
# ASG so a second pool in the same region cannot receive another pool's
# terminations.
###############################################################################

resource "aws_cloudwatch_event_rule" "lifecycle" {
  name        = "${local.name}-lifecycle"
  description = "SFU node launch and terminate lifecycle actions"

  event_pattern = jsonencode({
    source      = ["aws.autoscaling"]
    detail-type = ["EC2 Instance-launch Lifecycle Action", "EC2 Instance-terminate Lifecycle Action"]
    detail = {
      AutoScalingGroupName = [aws_autoscaling_group.this.name]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "lifecycle" {
  rule      = aws_cloudwatch_event_rule.lifecycle.name
  target_id = "node-lifecycle"
  arn       = var.node_lifecycle_lambda_arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 5
  }

  dead_letter_config {
    arn = var.node_lifecycle_dlq_arn
  }
}

resource "aws_lambda_permission" "lifecycle" {
  statement_id  = "${local.name}-allow-eventbridge"
  action        = "lambda:InvokeFunction"
  function_name = var.node_lifecycle_lambda_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lifecycle.arn
}

###############################################################################
# Alarm: a hook that never completes
#
# A stuck launch hook means no capacity is arriving during a scale-out; a stuck
# terminate hook means an instance is held for hours. Both are silent failures
# otherwise.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "lifecycle_dlq" {
  alarm_name          = "${local.name}-lifecycle-dlq"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_description   = "A node lifecycle action failed — EIP attach or drain did not complete. Runbook: ops/runbooks/sfu-incident.md"

  dimensions = { QueueName = var.node_lifecycle_dlq_name }

  alarm_actions = [var.pager_topic_arn]
  tags          = var.tags
}