// classroom-app/infra/core/security-groups.tf
/**
 * Control-plane security groups  (F7, F8)  [EXT]
 *
 * Everything in this stack talks through one of these. Two rules v7 adds:
 *
 *   realtime → SFU control   the realtime service is the only thing allowed to
 *                            reach an SFU node's control port (TCP 7443, mTLS).
 *                            Nothing else in the VPC, and nothing on the
 *                            internet, can create a transport on a node.
 *
 *   media nodes → registry   SFU and TURN nodes heartbeat into the state Redis
 *                            cluster and read room placement from it. That is
 *                            the only reason a media node reaches back into the
 *                            control plane, and it is control traffic; media
 *                            never crosses the Transit Gateway.
 *
 * Both are CIDR rules, not security group references, because a security group
 * reference does not work across regions — and media regions are separate VPCs
 * in separate regions. `var.media_regions[*].vpc_cidr` (narrowed by
 * `control_cidrs` where the private subnets are known) is the allowlist.
 *
 * Rules are individual `aws_vpc_security_group_*_rule` resources rather than
 * inline blocks, so a plan shows which single rule changed instead of
 * redrawing the whole group.
 */

locals {
  # Where media nodes live. Narrow to the private subnets when the media stack
  # publishes them; otherwise the region's VPC CIDR is the bound.
  media_cidrs = flatten([
    for media_region in var.media_regions : (
      media_region.enabled
      ? (length(media_region.control_cidrs) > 0 ? media_region.control_cidrs : [media_region.vpc_cidr])
      : []
    )
  ])

  sfu_control_port = 7443
  api_port         = 4000
  realtime_port    = 4100
  postgres_port    = 5432
  redis_port       = 6379
}

# ---------------------------------------------------------------------------
# Edge
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public ALB: HTTPS and WSS"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${local.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_v4" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS and WebSocket upgrade"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_v6" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv6         = "::/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# Only to redirect. The listener answers 301 and nothing reaches a task.
resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP, redirected to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  description                  = "to api tasks"
  referenced_security_group_id = aws_security_group.api_tasks.id
  from_port                    = local.api_port
  to_port                      = local.api_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_realtime" {
  security_group_id            = aws_security_group.alb.id
  description                  = "to realtime tasks"
  referenced_security_group_id = aws_security_group.realtime_tasks.id
  from_port                    = local.realtime_port
  to_port                      = local.realtime_port
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# Application tasks
# ---------------------------------------------------------------------------

resource "aws_security_group" "api_tasks" {
  name        = "${local.name}-api"
  description = "ECS Fargate: api"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${local.name}-api" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "realtime_tasks" {
  name        = "${local.name}-realtime"
  description = "ECS Fargate: realtime (signalling, chat, presence, collab)"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${local.name}-realtime" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "worker_tasks" {
  name        = "${local.name}-worker"
  description = "ECS Fargate: BullMQ workers and one-off migration tasks"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${local.name}-worker" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api_tasks.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = local.api_port
  to_port                      = local.api_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "realtime_from_alb" {
  security_group_id            = aws_security_group.realtime_tasks.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = local.realtime_port
  to_port                      = local.realtime_port
  ip_protocol                  = "tcp"
}

# Outbound HTTPS: AWS APIs through VPC endpoints, Stripe, APNs, FCM, SES.
resource "aws_vpc_security_group_egress_rule" "tasks_https" {
  for_each = {
    api      = aws_security_group.api_tasks.id
    realtime = aws_security_group.realtime_tasks.id
    worker   = aws_security_group.worker_tasks.id
  }

  security_group_id = each.value
  description       = "outbound HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "tasks_postgres" {
  for_each = {
    api      = aws_security_group.api_tasks.id
    realtime = aws_security_group.realtime_tasks.id
    worker   = aws_security_group.worker_tasks.id
  }

  security_group_id            = each.value
  description                  = "to PostgreSQL"
  referenced_security_group_id = aws_security_group.database.id
  from_port                    = local.postgres_port
  to_port                      = local.postgres_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "tasks_redis" {
  for_each = {
    api      = aws_security_group.api_tasks.id
    realtime = aws_security_group.realtime_tasks.id
    worker   = aws_security_group.worker_tasks.id
  }

  security_group_id            = each.value
  description                  = "to Redis (state and cache)"
  referenced_security_group_id = aws_security_group.redis.id
  from_port                    = local.redis_port
  to_port                      = local.redis_port
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# [V7] realtime → SFU control plane
# ---------------------------------------------------------------------------

/**
 * The private control RPC: createTransport, connect, produce, consume,
 * restartIce. mTLS on both ends; this rule is the network half of the same
 * decision. It is an egress rule with CIDRs because the SFU nodes sit in other
 * regions, where a security group reference cannot reach. The matching ingress
 * rule lives in modules/sfu-node-pool and allows exactly this stack's private
 * subnets.
 */
resource "aws_vpc_security_group_egress_rule" "realtime_to_sfu_control" {
  for_each = toset(local.media_cidrs)

  security_group_id = aws_security_group.realtime_tasks.id
  description       = "realtime → SFU control RPC (mTLS)"
  cidr_ipv4         = each.value
  from_port         = local.sfu_control_port
  to_port           = local.sfu_control_port
  ip_protocol       = "tcp"
}

# ---------------------------------------------------------------------------
# Data stores
# ---------------------------------------------------------------------------

resource "aws_security_group" "database" {
  name        = "${local.name}-rds"
  description = "RDS PostgreSQL: private subnets, no public route"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${local.name}-rds" })
}

resource "aws_vpc_security_group_ingress_rule" "database_from_tasks" {
  for_each = {
    api      = aws_security_group.api_tasks.id
    realtime = aws_security_group.realtime_tasks.id
    worker   = aws_security_group.worker_tasks.id
  }

  security_group_id            = aws_security_group.database.id
  description                  = "from ${each.key}"
  referenced_security_group_id = each.value
  from_port                    = local.postgres_port
  to_port                      = local.postgres_port
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis"
  description = "ElastiCache: state (noeviction) and cache (volatile-lru)"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${local.name}-redis" })
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_tasks" {
  for_each = {
    api      = aws_security_group.api_tasks.id
    realtime = aws_security_group.realtime_tasks.id
    worker   = aws_security_group.worker_tasks.id
  }

  security_group_id            = aws_security_group.redis.id
  description                  = "from ${each.key}"
  referenced_security_group_id = each.value
  from_port                    = local.redis_port
  to_port                      = local.redis_port
  ip_protocol                  = "tcp"
}

/**
 * [V7] Media nodes → registry. SFU nodes heartbeat
 * media:sfu:{region}:{nodeId} and TURN agents heartbeat
 * media:turn:{region}:{node}, both into the state cluster, every five seconds.
 * That heartbeat is what placement and TurnPoolSelector read, and it is the
 * only control-plane dependency a media region has: if this path breaks,
 * running rooms keep running and only new placements are affected.
 */
resource "aws_vpc_security_group_ingress_rule" "redis_from_media_nodes" {
  for_each = toset(local.media_cidrs)

  security_group_id = aws_security_group.redis.id
  description       = "media nodes → registry heartbeat (Transit Gateway)"
  cidr_ipv4         = each.value
  from_port         = local.redis_port
  to_port           = local.redis_port
  ip_protocol       = "tcp"
}

resource "aws_security_group" "opensearch" {
  name        = "${local.name}-opensearch"
  description = "OpenSearch: messages, community, profiles"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${local.name}-opensearch" })
}

resource "aws_vpc_security_group_ingress_rule" "opensearch_from_tasks" {
  for_each = {
    api    = aws_security_group.api_tasks.id
    worker = aws_security_group.worker_tasks.id
  }

  security_group_id            = aws_security_group.opensearch.id
  description                  = "from ${each.key}"
  referenced_security_group_id = each.value
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# VPC endpoints — keeps S3, ECR, Logs and Secrets traffic off NAT
# ---------------------------------------------------------------------------

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name}-vpce"
  description = "Interface endpoints: ECR, Logs, Secrets Manager, SSM"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${local.name}-vpce" })
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_from_vpc" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "HTTPS from inside the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------

/**
 * The node-lifecycle and turn-secret-rotation functions run in the VPC: the
 * first writes drain flags into the state cluster, the second checks that TURN
 * nodes accept a staged secret before signing with it.
 */
resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda"
  description = "VPC Lambdas: node lifecycle, secret rotation, IP range publisher"
  vpc_id      = aws_vpc.main.id
  tags        = merge(local.tags, { Name = "${local.name}-lambda" })
}

resource "aws_vpc_security_group_egress_rule" "lambda_https" {
  security_group_id = aws_security_group.lambda.id
  description       = "AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "lambda_redis" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "drain flags in the state cluster"
  referenced_security_group_id = aws_security_group.redis.id
  from_port                    = local.redis_port
  to_port                      = local.redis_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_lambda" {
  security_group_id            = aws_security_group.redis.id
  description                  = "from the lifecycle Lambda"
  referenced_security_group_id = aws_security_group.lambda.id
  from_port                    = local.redis_port
  to_port                      = local.redis_port
  ip_protocol                  = "tcp"
}