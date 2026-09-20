# infra/modules/sfu-node-pool/lifecycle-hooks.tf
#
# Lifecycle hooks of the SFU Auto Scaling group, declared as initial_lifecycle_hook blocks on the group
# (autoscaling.tf) so they exist before the first instance launches. Events go to EventBridge →
# infra/modules/node-lifecycle.
#
#   launch     The Lambda associates a free Elastic IP of the SFU pool, tags SfuSlot / SfuPublicIp and completes with
#              CONTINUE. publicAddress.js waits for exactly this tag. No address or no answer in 5 min: ABANDON.
#
#   terminate  The Lambda sets media:drain:sfu-<region>-<instance-id> (or completes at once when the instance runs
#              no task). lifecycle/drainSfu.js marks the node draining (placement stops sending new rooms), waits until
#              its rooms have ended or the drain timeout passes, records hook heartbeats meanwhile and completes the
#              hook. Timeout result CONTINUE: an unresponsive node never blocks scale-in forever.
#
# Owner: F1 Live Classrooms + F8 Real-Time Connectivity.

locals {
  lifecycle_hooks = {
    launch = {
      name                 = "${local.name}-launch"
      transition           = "autoscaling:EC2_INSTANCE_LAUNCHING"
      heartbeat_timeout    = 300
      default_result       = "ABANDON"
      notification_payload = { pool = "sfu", hook = "launch" }
    }
    terminate = {
      name                 = "${local.name}-terminate"
      transition           = "autoscaling:EC2_INSTANCE_TERMINATING"
      heartbeat_timeout    = 3600 # drainSfu.js records a heartbeat every 30 min while rooms drain
      default_result       = "CONTINUE"
      notification_payload = { pool = "sfu", hook = "terminate", drainTimeoutMinutes = var.drain_timeout_minutes }
    }
  }
}