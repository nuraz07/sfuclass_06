# infra/media-edge/outputs.tf
#
# Values other parts of the platform need from one media region. The GitHub environment variables used by
# deploy-sfu.yml and deploy-turn.yml are derived from these (see github_variables).
#
# Owner: F8 Real-Time Connectivity.

output "vpc_id" {
  description = "Media VPC of this region."
  value       = aws_vpc.media.id
}

output "ecs_cluster_name" {
  description = "ECS cluster of this region (<MEDIA_CLUSTER_PREFIX>-<region>)."
  value       = aws_ecs_cluster.media.name
}

output "sfu_public_ips" {
  description = "SFU Elastic IP pool (published for customer allowlists)."
  value       = local.sfu_ips
}

output "turn_public_ips" {
  description = "TURN Elastic IP pool (published for customer allowlists)."
  value       = local.turn_ips
}

output "turn_node_hostnames" {
  description = "TURN slot host names, one per address."
  value       = [for slot in local.turn_slots : "${slot}.${local.rtc_domain}"]
}

output "turn_regional_hostname" {
  description = "Health-checked regional TURN/STUN name used by the pre-join probe."
  value       = local.turn_regional_fqdn
}

output "prefix_list_ids" {
  description = "Managed prefix lists of this region."
  value = {
    sfu_public        = aws_ec2_managed_prefix_list.sfu_public.id
    turn_public       = aws_ec2_managed_prefix_list.turn_public.id
    sfu_public_global = aws_ec2_managed_prefix_list.sfu_public_global.id
  }
}

output "transit" {
  description = "Regional Transit Gateway and its peering to the hub."
  value = {
    transit_gateway_id    = aws_ec2_transit_gateway.media.id
    peering_attachment_id = aws_ec2_transit_gateway_peering_attachment.hub.id
  }
}

output "secret_replica_arns" {
  description = "Secrets as read by nodes in this region (replicas, or primaries in the core region)."
  value       = local.replica_arns
}

output "sfu" {
  description = "SFU pool: Auto Scaling group, ECS service and security group."
  value = {
    asg_name          = module.sfu_pool.asg_name
    service_name      = module.sfu_pool.service_name
    security_group_id = module.sfu_pool.security_group_id
  }
}

output "turn" {
  description = "TURN pool: Auto Scaling group, blue/green ECS services and security group."
  value = {
    asg_name          = module.turn_pool.asg_name
    service_names     = module.turn_pool.service_names
    security_group_id = module.turn_pool.security_group_id
  }
}

output "alarm_topic_arn" {
  description = "Regional alarm topic."
  value       = aws_sns_topic.alarms.arn
}

output "github_variables" {
  description = "Values for the GitHub environment variables of deploy-sfu.yml and deploy-turn.yml (identical for every region of an environment)."
  value = {
    MEDIA_CLUSTER_PREFIX     = "${local.name_prefix}-media"
    TURN_SERVICE_BASENAME    = "turn"
    TURN_CANARY_ALARM_PREFIX = "${local.name_prefix}-turn-canary"
    TURN_MIN_NODES           = tostring(var.turn.min_nodes)
    TURN_DRAIN_TIMEOUT_MIN   = tostring(var.turn.drain_timeout_minutes)
  }
}