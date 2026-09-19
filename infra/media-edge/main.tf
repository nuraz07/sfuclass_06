# infra/media-edge/main.tf
#
# Wires one media region together:
#
#   network.tf            VPC · public media subnets (SFU, TURN) · private subnets (lifecycle Lambda, endpoints)
#                         · transit subnets
#   transit.tf            regional Transit Gateway + peering to the core hub (control traffic only)
#   eip-pool.tf           pre-allocated Elastic IPs, one per possible node
#   prefix-lists.tf       the pools as managed prefix lists (local SFU, local TURN, SFU of all regions)
#   dns.tf                turn-<short>-NN per TURN address slot, turn-<region> health-checked multivalue name
#   secrets-replica.tf    regional KMS key for the Secrets Manager replicas the nodes read
#   observability.tf      alarm topic, alarms, dashboard
#   this file             ECS cluster and the four modules:
#
#     module.sfu_pool        infra/modules/sfu-node-pool       SFU nodes (ECS on EC2, host networking)
#     module.turn_pool       infra/modules/turn-node-pool      coturn + agent (ECS on EC2, blue/green services)
#     module.node_lifecycle  infra/modules/node-lifecycle      launch: attach EIP from the pool + tag the node
#                                                              terminate: set the drain flag, complete the hook
#     module.canary          infra/modules/connectivity-canary 1-minute TURN allocation canary from outside the VPC
#
# Module interfaces are fixed here; the modules implement exactly these inputs and outputs. Both pools also output
# capacity_provider_name, which is attached to the shared cluster below.
#
# Core outputs used (infra/core): transit_gateway_* · core_vpc_cidr · media_edge_supernet · rtc_domain ·
#   rtc_zone_id · turn_shared_secret_arn · turn_tls_secret_arn · sfu_control_node_tls_secret_arn ·
#   sfu_control_ca_secret_arn · redis_state_url_secret_arn · secrets_kms_key_arn ·
#   ecr_repository_names { sfu, capture, turn }
#
# Owner: F8 Real-Time Connectivity + F1 Live Classrooms.

locals {
  name_prefix  = "classroom-${var.environment}" # equals local.name_prefix of infra/core
  core         = data.terraform_remote_state.core.outputs
  rtc_domain   = local.core.rtc_domain
  cluster_name = "${local.name_prefix}-media-${var.region}" # MEDIA_CLUSTER_PREFIX-<region> in deploy-*.yml
  account_id   = data.aws_caller_identity.current.account_id

  # ECR repositories are replicated from the core region into every media region (infra/core/ecr.tf).
  ecr_registry = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  images = {
    sfu     = "${local.ecr_registry}/${local.core.ecr_repository_names.sfu}:${var.initial_image_tag}"
    capture = "${local.ecr_registry}/${local.core.ecr_repository_names.capture}:${var.initial_image_tag}"
    turn    = "${local.ecr_registry}/${local.core.ecr_repository_names.turn}:${var.initial_image_tag}"
  }
}

# ------------------------------------------------------------------ preconditions

locals {
  # IPv4 CIDRs as integer ranges, to check that this region lies inside the core's media supernet
  # (core routes and security groups only cover that range).
  vpc_base   = sum([for i, o in split(".", cidrhost(var.vpc_cidr, 0)) : tonumber(o) * pow(256, 3 - i)])
  vpc_size   = pow(2, 32 - tonumber(split("/", var.vpc_cidr)[1]))
  super_base = sum([for i, o in split(".", cidrhost(local.core.media_edge_supernet, 0)) : tonumber(o) * pow(256, 3 - i)])
  super_size = pow(2, 32 - tonumber(split("/", local.core.media_edge_supernet)[1]))
}

resource "terraform_data" "preconditions" {
  input = var.region

  lifecycle {
    precondition {
      condition     = local.vpc_base >= local.super_base && local.vpc_base + local.vpc_size <= local.super_base + local.super_size
      error_message = "vpc_cidr must lie inside the core media_edge_supernet."
    }
    precondition {
      condition     = var.eip_pool.sfu >= var.sfu.max_nodes + 1
      error_message = "eip_pool.sfu must be at least sfu.max_nodes + 1 (instance refresh)."
    }
    precondition {
      condition     = var.eip_pool.turn >= 2 * var.turn.max_nodes + 1 && var.eip_pool.turn <= 99
      error_message = "eip_pool.turn must be at least 2 x turn.max_nodes + 1 (blue/green) and at most 99 (two-digit node names)."
    }
    precondition {
      condition     = var.sfu.workers <= 64
      error_message = "At most 64 mediasoup workers: the TURN relay rules open rtc_port_base .. rtc_port_base + 63."
    }
  }
}

# ------------------------------------------------------------------ ECS cluster of this region

resource "aws_ecs_cluster" "media" {
  name = local.cluster_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# Both pools share the cluster, so their capacity providers are attached here, in one place (the resource owns the
# cluster's whole provider list). The pools create their services only after this exists.
resource "aws_ecs_cluster_capacity_providers" "media" {
  cluster_name       = aws_ecs_cluster.media.name
  capacity_providers = [module.sfu_pool.capacity_provider_name, module.turn_pool.capacity_provider_name]
}

# ------------------------------------------------------------------ SFU node pool

module "sfu_pool" {
  source = "../modules/sfu-node-pool"

  name_prefix  = local.name_prefix
  region       = var.region
  region_short = var.region_short
  vpc_id       = aws_vpc.media.id
  subnet_ids   = [for s in aws_subnet.public : s.id]
  ecs_cluster  = { name = aws_ecs_cluster.media.name, arn = aws_ecs_cluster.media.arn }
  images       = { sfu = local.images.sfu, capture = local.images.capture }

  capacity_provider_association = aws_ecs_cluster_capacity_providers.media.id
  instance_types                = var.sfu.instance_types
  architecture                  = var.sfu.architecture
  ipv6                          = var.sfu.ipv6

  workers              = var.sfu.workers
  rtc_port_base        = var.sfu.rtc_port_base
  pipe_port_range      = var.sfu.pipe_port_range
  control_port         = var.sfu.control_port
  control_ingress_cidr = local.core.core_vpc_cidr # realtime service, over the Transit Gateway

  min_nodes             = var.sfu.min_nodes
  max_nodes             = var.sfu.max_nodes
  target_load_score     = var.sfu.target_load_score
  max_load_score        = var.sfu.max_load_score
  consumers_per_worker  = var.sfu.consumers_per_worker
  egress_capacity_mbps  = var.sfu.egress_capacity_mbps
  drain_timeout_minutes = var.sfu.drain_timeout_minutes
  spot_allowed          = var.sfu.spot_allowed

  secret_arns = {
    redis_state_url = local.replica_arns.redis_state_url
    control_tls     = local.replica_arns.sfu_control_node_tls
    control_ca      = local.replica_arns.sfu_control_ca
  }
  secrets_kms_key_arn = local.secrets_kms_key_arn
  logs_kms_key_arn    = aws_kms_key.logs.arn
  log_retention_days  = var.log_retention_days
  alarm_topic_arn     = aws_sns_topic.alarms.arn
}

# ------------------------------------------------------------------ TURN node pool

module "turn_pool" {
  source = "../modules/turn-node-pool"

  name_prefix  = local.name_prefix
  region       = var.region
  region_short = var.region_short
  vpc_id       = aws_vpc.media.id
  subnet_ids   = [for s in aws_subnet.public : s.id]
  ecs_cluster  = { name = aws_ecs_cluster.media.name, arn = aws_ecs_cluster.media.arn }
  image        = local.images.turn

  capacity_provider_association = aws_ecs_cluster_capacity_providers.media.id
  instance_types                = var.turn.instance_types
  architecture                  = var.turn.architecture
  realm                         = local.rtc_domain
  service_base                  = "turn" # services turn-blue / turn-green (deploy-turn.yml)

  min_nodes             = var.turn.min_nodes
  max_nodes             = var.turn.max_nodes
  capacity_mbps         = var.turn.capacity_mbps
  total_quota           = var.turn.total_quota
  user_quota            = var.turn.user_quota
  max_bps               = var.turn.max_bps
  bps_capacity          = var.turn.bps_capacity
  relay_port_range      = var.turn.relay_port_range
  target_load_ratio     = var.turn.target_load_ratio
  drain_timeout_minutes = var.turn.drain_timeout_minutes
  spot_allowed          = var.turn.spot_allowed

  # Relay traffic only to and from SFU addresses of every media region (cross-region backup relays included).
  sfu_prefix_list_id = aws_ec2_managed_prefix_list.sfu_public_global.id
  sfu_rtc_port_range = { min = var.sfu.rtc_port_base, max = var.sfu.rtc_port_base + 63 }
  registry_cidr      = local.core.core_vpc_cidr # state Redis over the Transit Gateway

  secret_arns = {
    turn_shared_secret = local.replica_arns.turn_shared_secret
    turn_tls           = local.replica_arns.turn_tls
    redis_state_url    = local.replica_arns.redis_state_url
  }
  secrets_kms_key_arn = local.secrets_kms_key_arn
  logs_kms_key_arn    = aws_kms_key.logs.arn
  log_retention_days  = var.log_retention_days
  alarm_topic_arn     = aws_sns_topic.alarms.arn
}

# ------------------------------------------------------------------ node lifecycle (EIP attach, drain)

module "node_lifecycle" {
  source = "../modules/node-lifecycle"

  name_prefix = local.name_prefix
  region      = var.region
  vpc_id      = aws_vpc.media.id
  subnet_ids  = [for s in aws_subnet.private : s.id]

  pools = {
    sfu = {
      asg_name            = module.sfu_pool.asg_name
      asg_arn             = module.sfu_pool.asg_arn
      launch_hook_name    = module.sfu_pool.lifecycle_hook_names.launch
      terminate_hook_name = module.sfu_pool.lifecycle_hook_names.terminate
      eip_allocation_ids  = [for e in aws_eip.sfu : e.allocation_id]
      node_tags           = false # SFU nodes need no DNS name; they are addressed through the registry

      drain_timeout_minutes = var.sfu.drain_timeout_minutes
    }
    turn = {
      asg_name            = module.turn_pool.asg_name
      asg_arn             = module.turn_pool.asg_arn
      launch_hook_name    = module.turn_pool.lifecycle_hook_names.launch
      terminate_hook_name = module.turn_pool.lifecycle_hook_names.terminate
      eip_allocation_ids  = [for e in aws_eip.turn : e.allocation_id]
      node_tags           = true # copies TurnNodeName / TurnHostname / TurnPublicIp from the EIP to the instance

      drain_timeout_minutes = var.turn.drain_timeout_minutes
    }
  }

  redis_state_url_secret_arn = local.replica_arns.redis_state_url
  secrets_kms_key_arn        = local.secrets_kms_key_arn
  logs_kms_key_arn           = aws_kms_key.logs.arn
  log_retention_days         = var.log_retention_days
  alarm_topic_arn            = aws_sns_topic.alarms.arn
  metrics_namespace          = "Classroom/MediaEdge" # FreeEips per pool, used by observability.tf
}

# ------------------------------------------------------------------ connectivity canary

module "canary" {
  source = "../modules/connectivity-canary"

  name_prefix         = local.name_prefix
  region              = var.region
  enabled             = var.canary.enabled
  schedule            = var.canary.schedule
  regional_host       = local.turn_regional_fqdn
  realm               = local.rtc_domain
  turn_secret_arn     = local.replica_arns.turn_shared_secret
  secrets_kms_key_arn = local.secrets_kms_key_arn
  logs_kms_key_arn    = aws_kms_key.logs.arn
  log_retention_days  = var.log_retention_days
  alarm_topic_arn     = aws_sns_topic.alarms.arn
  alarm_name          = "${local.name_prefix}-turn-canary-${var.region}" # TURN_CANARY_ALARM_PREFIX-<region>
}