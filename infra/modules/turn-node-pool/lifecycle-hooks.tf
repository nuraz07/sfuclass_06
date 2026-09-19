# infra/modules/turn-node-pool/lifecycle-hooks.tf
#
# Lifecycle hooks of the TURN Auto Scaling group. They are declared as initial_lifecycle_hook blocks on the group
# (autoscaling.tf) so they exist before the very first instance launches. Auto Scaling sends every hook event to
# EventBridge, where infra/modules/node-lifecycle picks it up.
#
#   launch     Pending:Wait. The node-lifecycle Lambda associates a free Elastic IP of the TURN pool, tags the instance
#              (TurnNodeName, TurnHostname, TurnPublicIp) and completes with CONTINUE. The bootstrap waits for exactly
#              these tags before coturn starts. No free address or no answer within 5 min: ABANDON — the instance is
#              replaced instead of running without a published address.
#
#   terminate  Terminating:Wait. The Lambda sets the drain flag media:drain:<node> (or completes at once when the
#              instance runs no task). The agent leaves the registry, waits until allocations reach zero or the drain
#              timeout passes, records a hook heartbeat every 30 min and completes the hook itself
#              (turn/agent/src/drain.js). If nobody completes it, the hook times out with CONTINUE, i.e. the instance
#              terminates anyway: an unresponsive node must never block scale-in forever.
#
# Owner: F8 Real-Time Connectivity.

locals {
  lifecycle_hooks = {
    launch = {
      name                 = "${local.name}-launch"
      transition           = "autoscaling:EC2_INSTANCE_LAUNCHING"
      heartbeat_timeout    = 300
      default_result       = "ABANDON"
      notification_payload = { pool = "turn", hook = "launch" }
    }
    terminate = {
      name              = "${local.name}-terminate"
      transition        = "autoscaling:EC2_INSTANCE_TERMINATING"
      heartbeat_timeout = 3600 # the agent records a heartbeat every 30 min while draining
      # CONTINUE: a node that cannot complete its own drain is still terminated.
      default_result       = "CONTINUE"
      notification_payload = { pool = "turn", hook = "terminate", drainTimeoutMinutes = var.drain_timeout_minutes }
    }
  }
}