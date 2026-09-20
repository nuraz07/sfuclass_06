# infra/modules/sfu-node-pool/outputs.tf
#
# Consumed by infra/media-edge (node-lifecycle wiring, capacity provider association, outputs for deploy-sfu.yml).
#
# Owner: F1 Live Classrooms + F8 Real-Time Connectivity.

output "asg_name" {
  description = "Auto Scaling group of the SFU nodes."
  value       = aws_autoscaling_group.sfu.name
}

output "asg_arn" {
  description = "ARN of the Auto Scaling group."
  value       = aws_autoscaling_group.sfu.arn
}

output "lifecycle_hook_names" {
  description = "Lifecycle hooks handled by infra/modules/node-lifecycle."
  value = {
    launch    = local.lifecycle_hooks.launch.name
    terminate = local.lifecycle_hooks.terminate.name
  }
}

output "service_name" {
  description = "Service base name; the services are <service_name>-blue and <service_name>-green (SFU_SERVICE_BASENAME)."
  value       = var.service_base
}

output "service_names" {
  description = "Blue/green ECS services."
  value       = [for c in local.colours : aws_ecs_service.sfu[c].name]
}

output "capacity_provider_name" {
  description = "ECS capacity provider; attached to the cluster by the root module."
  value       = aws_ecs_capacity_provider.sfu.name
}

output "security_group_id" {
  description = "Security group of the SFU nodes."
  value       = aws_security_group.sfu.id
}

output "task_definition_family" {
  description = "Task definition family shared by both colours."
  value       = aws_ecs_task_definition.sfu.family
}

output "log_group_name" {
  description = "Log group of the SFU and capture containers."
  value       = aws_cloudwatch_log_group.sfu.name
}