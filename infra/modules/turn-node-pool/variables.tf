# infra/modules/turn-node-pool/variables.tf
#
# Interface of the TURN node pool, as called by infra/media-edge/main.tf (module "turn_pool").
#
# Owner: F8 Real-Time Connectivity.

variable "name_prefix" {
  description = "Resource name prefix of the environment, e.g. classroom-prod."
  type        = string
}

variable "region" {
  description = "Media region, e.g. eu-central-1."
  type        = string
}

variable "region_short" {
  description = "Short region code used in names, e.g. euc1."
  type        = string
}

variable "vpc_id" {
  description = "Media VPC."
  type        = string
}

variable "subnet_ids" {
  description = "Public media subnets (one per AZ). Nodes get an Elastic IP from the pool at launch."
  type        = list(string)
}

variable "ecs_cluster" {
  description = "ECS cluster of the media region."
  type = object({
    name = string
    arn  = string
  })
}

variable "capacity_provider_association" {
  description = "ID of aws_ecs_cluster_capacity_providers in the root module. The services are created only after the capacity provider is attached to the cluster."
  type        = string
}

variable "image" {
  description = "TURN image (turn/Dockerfile) in the regional ECR replica, tag or digest. deploy-turn.yml owns it after the first apply."
  type        = string
}

variable "instance_types" {
  description = "Instance types in order of preference (mixed-instances policy)."
  type        = list(string)
}

variable "architecture" {
  description = "arm64 or x86_64; must match the instance types and the image."
  type        = string

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "realm" {
  description = "TURN realm = rtc domain; node host names are <node>.<realm>."
  type        = string
}

variable "service_base" {
  description = "ECS services are <service_base>-blue and <service_base>-green (deploy-turn.yml)."
  type        = string
  default     = "turn"
}

variable "min_nodes" {
  description = "Nodes of the active colour at creation and the floor deploy-turn.yml keeps (TURN_MIN_NODES)."
  type        = number
}

variable "max_nodes" {
  description = "Upper bound of the active colour. The Auto Scaling group allows 2 x max_nodes + 1 during blue/green switches."
  type        = number
}

variable "capacity_mbps" {
  description = "Planned relayed egress per node (Mbit/s); published by the agent for LoadRatio."
  type        = number
}

variable "total_quota" {
  description = "coturn total-quota: allocations per node."
  type        = number
}

variable "user_quota" {
  description = "coturn user-quota: allocations per credential (device session)."
  type        = number
}

variable "max_bps" {
  description = "coturn max-bps per allocation in bytes/s (0 = unlimited)."
  type        = number
}

variable "bps_capacity" {
  description = "coturn bps-capacity per node in bytes/s (0 = unlimited)."
  type        = number
}

variable "relay_port_range" {
  description = "coturn relay port range; must lie above the node's ephemeral port range (launch template sets 32768-49151)."
  type        = object({ min = number, max = number })

  validation {
    condition     = var.relay_port_range.min >= 49152 && var.relay_port_range.max <= 65535 && var.relay_port_range.min < var.relay_port_range.max
    error_message = "relay_port_range must lie within 49152-65535."
  }
}

variable "target_load_ratio" {
  description = "Scale-out target for Classroom/Turn LoadRatio (region average)."
  type        = number
}

variable "drain_timeout_minutes" {
  description = "Upper bound for draining allocations before a node is stopped."
  type        = number
}

variable "spot_allowed" {
  description = "Allow Spot capacity (development only: a Spot interruption cuts relayed sessions)."
  type        = bool
}

variable "sfu_prefix_list_id" {
  description = "Managed prefix list with the SFU addresses of all media regions; the only relay destinations allowed."
  type        = string
}

variable "sfu_rtc_port_range" {
  description = "SFU WebRtcServer port range the relay may send to."
  type        = object({ min = number, max = number })
}

variable "registry_cidr" {
  description = "Core VPC CIDR (state Redis, reached over the Transit Gateway)."
  type        = string
}

variable "secret_arns" {
  description = "Secrets as readable in this region (replicas outside the core region)."
  type = object({
    turn_shared_secret = string
    turn_tls           = string
    redis_state_url    = string
  })
}

variable "secrets_kms_key_arn" {
  description = "KMS key that encrypts the secrets in this region."
  type        = string
}

variable "logs_kms_key_arn" {
  description = "KMS key for the log group."
  type        = string
}

variable "log_retention_days" {
  description = "Retention of the TURN log group."
  type        = number
}

variable "alarm_topic_arn" {
  description = "Regional alarm topic."
  type        = string
}

variable "probe_peer_ip" {
  description = "Public IPv4 the agent's self-probe uses for the permission test (no traffic is sent to it)."
  type        = string
  default     = "1.1.1.1"
}

variable "redis_cluster_mode" {
  description = "State Redis runs in cluster mode."
  type        = bool
  default     = false
}

variable "root_volume_gb" {
  description = "Root volume size of a node."
  type        = number
  default     = 30
}