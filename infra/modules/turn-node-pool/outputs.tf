# infra/modules/turn-node-pool/outputs.tf
#
# Consumed by infra/media-edge (node-lifecycle wiring, capacity provider association, outputs for deploy-turn.yml).
#
# Owner: F8 Real-Time Connectivity.

output "asg_name" {
  description = "Auto Scaling group of the TURN nodes."
  value       = aws_autoscaling_group.turn.name
}

output "asg_arn" {
  description = "ARN of the Auto Scaling group."
  value       = aws_autoscaling_group.turn.arn
}

output "lifecycle_hook_names" {
  description = "Lifecycle hooks handled by infra/modules/node-lifecycle."
  value = {
    launch    = local.lifecycle_hooks.launch.name
    terminate = local.lifecycle_hooks.terminate.name
  }
}

output "service_names" {
  description = "Blue/green ECS services (TURN_SERVICE_BASENAME-blue / -green in deploy-turn.yml)."
  value       = [for c in local.colours : aws_ecs_service.turn[c].name]
}

output "capacity_provider_name" {
  description = "ECS capacity provider; attached to the cluster by the root module."
  value       = aws_ecs_capacity_provider.turn.name
}

output "security_group_id" {
  description = "Security group of the TURN nodes."
  value       = aws_security_group.turn.id
}

output "task_definition_family" {
  description = "Task definition family shared by both colours."
  value       = aws_ecs_task_definition.turn.family
}

output "log_group_name" {
  description = "Log group of coturn and the agent (streams coturn/… and agent/…)."
  value       = aws_cloudwatch_log_group.turn.name
}