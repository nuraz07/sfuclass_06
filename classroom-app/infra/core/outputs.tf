// classroom-app/infra/core/outputs.tf
/**
 * Core stack outputs  (F7, F8)  [EXT]
 *
 * Two audiences:
 *
 *   media-edge   each regional media stack reads this state remotely. It needs
 *                the registry endpoint its nodes heartbeat into, the Transit
 *                Gateway to attach to, the secret ARNs its nodes fetch at boot,
 *                the image repositories, and the CIDRs to open on the control
 *                and registry paths.
 *   CI and ops   cluster and service names, the ALB, the deploy role.
 *
 * Nothing here is a secret value; secrets are referenced by ARN and resolved at
 * runtime by the process that is allowed to read them.
 */

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "Control-plane VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "Opened on the SFU control port and the registry path by media-edge."
  value       = var.vpc_cidr
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "private_subnet_cidrs" {
  description = "The exact sources media-edge security groups allow, rather than the whole VPC."
  value       = aws_subnet.private[*].cidr_block
}

output "transit_gateway_id" {
  description = "[V7] Hub for media-region peering. Control traffic only; media never crosses it."
  value       = aws_ec2_transit_gateway.hub.id
}

output "transit_gateway_route_table_id" {
  value = aws_ec2_transit_gateway_route_table.hub.id
}

# ---------------------------------------------------------------------------
# Registry and data plane
# ---------------------------------------------------------------------------

output "redis_state_endpoint" {
  description = <<-EOT
    [V7] The registry SFU and TURN nodes heartbeat into (media:sfu:*,
    media:turn:*, room:*, media:drain:*). The state cluster is noeviction: it
    must never drop a registry key or a queued job.
  EOT
  value       = aws_elasticache_replication_group.state.configuration_endpoint_address
}

output "redis_state_port" {
  value = aws_elasticache_replication_group.state.port
}

output "redis_cache_endpoint" {
  value = aws_elasticache_replication_group.cache.configuration_endpoint_address
}

output "database_endpoint" {
  value = aws_db_instance.main.address
}

output "database_read_endpoint" {
  value = try(aws_db_instance.replica[0].address, null)
}

# ---------------------------------------------------------------------------
# Secrets — ARNs, never values
# ---------------------------------------------------------------------------

output "secret_arns" {
  description = "Every managed secret by name; task definitions reference these."
  value       = local.secret_arns
}

output "turn_secret_arn" {
  description = "[V7] TURN REST shared secret ring. Replicated into every media region."
  value       = aws_secretsmanager_secret.turn_shared_secret.arn
}

output "turn_tls_secret_arn" {
  description = "[V7] ACME certificate for *.${"$"}{var.rtc_domain}, fetched by TURN nodes at boot."
  value       = aws_secretsmanager_secret.turn_tls.arn
}

output "sfu_control_secret_arns" {
  description = "[V7] mTLS material for the control RPC: CA plus the SFU server certificate."
  value = {
    ca        = local.secret_arns["sfu-control/ca"]
    tls_cert  = local.secret_arns["sfu-control/sfu/tls-cert"]
    tls_key   = local.secret_arns["sfu-control/sfu/tls-key"]
  }
}

output "secrets_kms_key_arn" {
  description = "Media regions grant their nodes Decrypt on the replica key derived from this."
  value       = aws_kms_key.secrets.arn
}

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

output "ecr_repository_urls" {
  description = "[V7] api · sfu · capture · worker · turn, replicated to every media region."
  value       = local.ecr_repository_urls
}

# ---------------------------------------------------------------------------
# Services and edge
# ---------------------------------------------------------------------------

output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "alb_zone_id" {
  value = aws_lb.main.zone_id
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "service_names" {
  description = "For deploy workflows: one service per role."
  value = {
    api      = aws_ecs_service.api.name
    realtime = aws_ecs_service.realtime.name
    worker   = aws_ecs_service.worker.name
  }
}

output "realtime_security_group_id" {
  description = "Informational: SFU ingress is by CIDR, since a group reference cannot cross regions."
  value       = aws_security_group.realtime_tasks.id
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

output "primary_zone_id" {
  value = aws_route53_zone.primary.zone_id
}

output "rtc_zone_id" {
  description = "[V7] Delegated media zone; the lifecycle Lambda writes turn-<region>-NN records here."
  value       = aws_route53_zone.rtc.zone_id
}

output "rtc_domain" {
  value = var.rtc_domain
}

output "cdn_domain" {
  description = "Also where media-ip-ranges.json is published for customer firewalls."
  value       = aws_cloudfront_distribution.web.domain_name
}

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

output "media_regions" {
  description = "[V7] What the control plane believes exists. A region appears in placement once its first nodes heartbeat."
  value = [
    for media_region in var.media_regions : {
      region   = media_region.region
      vpc_cidr = media_region.vpc_cidr
      enabled  = media_region.enabled
    }
  ]
}

output "lambda_role_arns" {
  description = "[V7] node-lifecycle · turn-secret-rotation · acme-renewer · publish-ip-ranges · turn-canary."
  value       = local.lambda_role_arns
}

output "task_execution_role_arn" {
  value = aws_iam_role.task_execution.arn
}

output "task_role_arns" {
  value = local.task_role_arns
}

output "alarm_topic_arn" {
  description = "Where media-edge alarms page as well, so on-call has one destination."
  value       = aws_sns_topic.alarms.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.services.name
}

output "deploy_role_arn" {
  description = "Assumed by GitHub Actions through OIDC; no long-lived keys exist."
  value       = aws_iam_role.github_actions.arn
}