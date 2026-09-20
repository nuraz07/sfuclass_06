###############################################################################
# infra/modules/sfu-node-pool/outputs.tf
#
# What the media-edge stack and the operator tooling need from this pool.
###############################################################################

output "security_group_id" {
  description = "SFU node security group. turn-node-pool references it for the relay path; media-edge/observability.tf tags alarms with it."
  value       = aws_security_group.this.id
}

output "autoscaling_group_name" {
  description = "Target of the drain scripts and of deploy-sfu.yml's instance refresh"
  value       = aws_autoscaling_group.this.name
}

output "autoscaling_group_arn" {
  value = aws_autoscaling_group.this.arn
}

output "capacity_provider_name" {
  value = aws_ecs_capacity_provider.this.name
}

output "service_name" {
  value = aws_ecs_service.sfu.name
}

output "task_definition_arn" {
  description = "Pinned in the rollback runbook: a rollback is a revert to the previous revision"
  value       = aws_ecs_task_definition.sfu.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.sfu.name
}

###############################################################################
# The published contract
#
# These three values together are what enterprise and school IT allowlist, and
# what functions/publish-ip-ranges writes into media-ip-ranges.json. Changing
# any of them is a customer-facing change, not an implementation detail.
###############################################################################

output "rtc_port_min" {
  description = "First WebRtcServer port (UDP and TCP)"
  value       = local.rtc_port_min
}

output "rtc_port_max" {
  description = "Last WebRtcServer port; one port per mediasoup worker"
  value       = local.rtc_port_max
}

output "published_ports" {
  description = "Ready-made entry for media-ip-ranges.json"
  value = {
    region   = var.region
    role     = "sfu"
    protocol = ["udp", "tcp"]
    from     = local.rtc_port_min
    to       = local.rtc_port_max
  }
}

output "control_port" {
  description = "Private mTLS control port. Never published to customers."
  value       = var.control_port
}