###############################################################################
# infra/core/data.tf
#
# Stateful backends: PostgreSQL (+ read replica), two Redis clusters,
# OpenSearch.  (F2, F3, F4, F6, F7)
#
# v6 -> v7 correction: v6 had ONE Redis cluster for BullMQ, the seat
# reservation Lua script and every cache, with an eviction alarm bolted on.
# Those workloads have opposite requirements:
#
#   state  maxmemory-policy = noeviction   BullMQ, seat reservations, room and
#                                          media-node registries, drain flags,
#                                          rate limits, session revocation.
#                                          Evicting here loses a job or a paid
#                                          seat. Alarm at 70 % memory.
#   cache  maxmemory-policy = volatile-lru entitlements, presence, unread
#                                          counters, Socket.IO sharded Pub/Sub.
#                                          Evicting here is correct behaviour.
#
# server/src/db/redis.js asserts both policies at boot, so a hand-edited
# parameter group fails the deploy instead of surfacing months later.
###############################################################################

###############################################################################
# Subnet groups — everything here is private, no internet route
###############################################################################

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db"
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name_prefix}-cache"
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}

###############################################################################
# PostgreSQL
###############################################################################

resource "aws_db_parameter_group" "postgres" {
  name        = "${local.name_prefix}-pg"
  family      = var.rds_parameter_group_family # e.g. postgres16
  description = "TLS enforced, statement timeout, slow query logging"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    # A query that runs longer than this is a bug, not a slow query. The
    # application sets its own per-pool timeout as well (db/pool.js).
    name  = "statement_timeout"
    value = "30000"
  }

  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "60000"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  tags = local.tags
}

resource "aws_db_instance" "primary" {
  identifier     = "${local.name_prefix}-pg"
  engine         = "postgres"
  engine_version = var.rds_engine_version
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  db_name  = "classroom"
  username = "classroom_admin"
  # Managed rotation; the application reads the rotated secret, never a literal.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.secrets.arn

  multi_az               = var.rds_multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.database.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  publicly_accessible    = false
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  # Backups: PITR plus a nightly snapshot copied to a second region by
  # backup.tf. RPO 5 min, RTO 1 h (§10.2).
  backup_retention_period   = var.rds_backup_retention_days
  backup_window             = "02:00-03:00"
  maintenance_window        = "sun:03:30-sun:04:30"
  copy_tags_to_snapshot     = true
  delete_automated_backups  = false
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-pg-final-${formatdate("YYYYMMDDhhmm", timestamp())}"

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.rds.arn
  performance_insights_retention_period = 7
  monitoring_interval                   = 30
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  deletion_protection        = var.environment == "prod"
  apply_immediately          = var.environment != "prod"

  tags = merge(local.tags, { Name = "${local.name_prefix}-pg" })

  lifecycle {
    ignore_changes = [final_snapshot_identifier]
  }
}

# Feeds, search fallback and reporting read from here. Writes never do —
# db/pool.js keeps two pools and only the read pool points at this endpoint.
resource "aws_db_instance" "replica" {
  count = var.rds_read_replica_enabled ? 1 : 0

  identifier          = "${local.name_prefix}-pg-replica"
  replicate_source_db = aws_db_instance.primary.identifier
  instance_class      = var.rds_replica_instance_class

  storage_encrypted      = true
  kms_key_id             = aws_kms_key.rds.arn
  vpc_security_group_ids = [aws_security_group.database.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  publicly_accessible    = false

  performance_insights_enabled = true
  monitoring_interval          = 30
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  auto_minor_version_upgrade = true
  skip_final_snapshot        = true
  deletion_protection        = var.environment == "prod"

  tags = merge(local.tags, { Name = "${local.name_prefix}-pg-replica", Role = "read" })
}

###############################################################################
# Redis — state cluster (noeviction)
###############################################################################

resource "aws_elasticache_parameter_group" "state" {
  name        = "${local.name_prefix}-redis-state"
  family      = var.elasticache_parameter_group_family # e.g. redis7
  description = "BullMQ, reservations, registries: must never evict"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }

  # Sharded Pub/Sub is used on the cache cluster, but keeping the keyspace
  # notification surface identical avoids surprises when debugging.
  parameter {
    name  = "notify-keyspace-events"
    value = "Kg$lshzxet"
  }

  tags = local.tags
}

resource "aws_elasticache_replication_group" "state" {
  replication_group_id = "${local.name_prefix}-state"
  description          = "State: BullMQ, seat reservations, SFU/TURN registries, rate limits"

  engine         = "redis"
  engine_version = var.elasticache_engine_version
  node_type      = var.redis_state_node_type
  port           = 6379

  # Cluster mode: the registries and BullMQ shard cleanly by key.
  cluster_mode                = "enabled"
  num_node_groups             = var.redis_state_shards
  replicas_per_node_group     = 1
  automatic_failover_enabled  = true
  multi_az_enabled            = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.cache.id]
  parameter_group_name = aws_elasticache_parameter_group.state.name

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = aws_kms_key.cache.arn
  auth_token                 = random_password.redis_state_auth.result
  auth_token_update_strategy = "ROTATE"

  # A daily snapshot is enough: registries rebuild from heartbeats in 15 s and
  # queued jobs are re-driven from their sources of truth (§10.2).
  snapshot_retention_limit = 7
  snapshot_window          = "01:00-02:00"
  maintenance_window       = "sun:04:30-sun:05:30"

  apply_immediately          = var.environment != "prod"
  auto_minor_version_upgrade = true

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_state.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "engine-log"
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-state", EvictionPolicy = "noeviction" })
}

###############################################################################
# Redis — cache cluster (volatile-lru)
###############################################################################

resource "aws_elasticache_parameter_group" "cache" {
  name        = "${local.name_prefix}-redis-cache"
  family      = var.elasticache_parameter_group_family
  description = "Entitlements, presence, unread counters, Socket.IO sharded Pub/Sub"

  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"
  }

  tags = local.tags
}

resource "aws_elasticache_replication_group" "cache" {
  replication_group_id = "${local.name_prefix}-cache"
  description          = "Cache and Socket.IO sharded Pub/Sub; eviction expected"

  engine         = "redis"
  engine_version = var.elasticache_engine_version
  node_type      = var.redis_cache_node_type
  port           = 6379

  cluster_mode               = "enabled"
  num_node_groups            = var.redis_cache_shards
  replicas_per_node_group    = 1
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.cache.id]
  parameter_group_name = aws_elasticache_parameter_group.cache.name

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = aws_kms_key.cache.arn
  auth_token                 = random_password.redis_cache_auth.result
  auth_token_update_strategy = "ROTATE"

  # Reconstructible by definition — no snapshots.
  snapshot_retention_limit = 0
  maintenance_window       = "sun:05:30-sun:06:30"

  apply_immediately          = var.environment != "prod"
  auto_minor_version_upgrade = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-cache", EvictionPolicy = "volatile-lru" })
}

resource "random_password" "redis_state_auth" {
  length  = 48
  special = false
}

resource "random_password" "redis_cache_auth" {
  length  = 48
  special = false
}

resource "aws_cloudwatch_log_group" "redis_state" {
  name              = "/elasticache/${local.name_prefix}/state"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
  tags              = local.tags
}

###############################################################################
# OpenSearch — chat, community and course search
###############################################################################

resource "aws_opensearch_domain" "this" {
  domain_name    = "${local.name_prefix}-search"
  engine_version = var.opensearch_engine_version

  cluster_config {
    instance_type            = var.opensearch_instance_type
    instance_count           = var.opensearch_instance_count
    zone_awareness_enabled   = var.opensearch_instance_count > 1
    dedicated_master_enabled = var.opensearch_dedicated_master

    dynamic "zone_awareness_config" {
      for_each = var.opensearch_instance_count > 1 ? [1] : []
      content {
        availability_zone_count = var.opensearch_instance_count >= 3 ? 3 : 2
      }
    }

    dedicated_master_type  = var.opensearch_dedicated_master ? var.opensearch_master_instance_type : null
    dedicated_master_count = var.opensearch_dedicated_master ? 3 : null
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.opensearch_volume_size
  }

  vpc_options {
    subnet_ids = slice(aws_subnet.private[*].id, 0, var.opensearch_instance_count >= 3 ? 3 : 2)
    security_group_ids = [aws_security_group.search.id]
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = aws_kms_key.search.arn
  }

  node_to_node_encryption { enabled = true }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = false

    master_user_options {
      master_user_arn = aws_iam_role.api_task.arn
    }
  }

  log_publishing_options {
    log_type                 = "ES_APPLICATION_LOGS"
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch.arn
  }

  # No backups: every index is rebuilt from PostgreSQL by a reindex job
  # (RTO 2 h, §10.2). The source of truth is never OpenSearch.
  tags = merge(local.tags, { Name = "${local.name_prefix}-search" })
}

resource "aws_cloudwatch_log_group" "opensearch" {
  name              = "/aws/opensearch/${local.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
  tags              = local.tags
}

###############################################################################
# Connection strings, handed to tasks as Secrets Manager references
###############################################################################

resource "aws_secretsmanager_secret" "redis" {
  name       = "${local.name_prefix}/redis"
  kms_key_id = aws_kms_key.secrets.arn
  tags       = local.tags
}

resource "aws_secretsmanager_secret_version" "redis" {
  secret_id = aws_secretsmanager_secret.redis.id

  secret_string = jsonencode({
    state_url = "rediss://:${random_password.redis_state_auth.result}@${aws_elasticache_replication_group.state.configuration_endpoint_address}:6379"
    cache_url = "rediss://:${random_password.redis_cache_auth.result}@${aws_elasticache_replication_group.cache.configuration_endpoint_address}:6379"
  })
}