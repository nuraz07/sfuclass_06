###############################################################################
# infra/modules/sfu-node-pool/variables.tf
#
# Inputs for one SFU pool in one media region.  (F1, F8)
###############################################################################

###############################################################################
# Identity and placement
###############################################################################

variable "name_prefix" {
  description = "Environment-scoped prefix, e.g. classroom-prod"
  type        = string
}

variable "region" {
  description = "Media region this pool runs in"
  type        = string
}

variable "vpc_id" {
  description = "Media-edge VPC"
  type        = string
}

variable "public_media_subnet_ids" {
  description = "Public media subnets, one per AZ. Nodes need a public route because clients reach them directly."
  type        = list(string)

  validation {
    condition     = length(var.public_media_subnet_ids) >= 2
    error_message = "At least two AZs are required; production uses three."
  }
}

variable "control_plane_cidr" {
  description = "Control-plane VPC CIDR, allowed to reach the control port over Transit Gateway"
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}

###############################################################################
# Capacity
###############################################################################

variable "instance_type" {
  description = "Network-optimised instance. Capacity is bounded by egress and packets per second, not by CPU."
  type        = string
  default     = "c7gn.2xlarge"
}

variable "cpu_architecture" {
  type    = string
  default = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be arm64 or x86_64."
  }
}

variable "ami_id" {
  description = "Override the ECS-optimised AMI. Null means the SSM recommended image."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  type    = number
  default = 100
}

variable "min_nodes" {
  type    = number
  default = 2
}

variable "max_nodes" {
  type    = number
  default = 20
}

variable "desired_nodes" {
  type    = number
  default = 2
}

variable "allow_spot" {
  description = "Spot for media nodes: dev only. A two-minute interruption notice is shorter than a lesson."
  type        = bool
  default     = false
}

variable "task_cpu" {
  type    = number
  default = 7168
}

variable "task_memory" {
  type    = number
  default = 14336
}

###############################################################################
# mediasoup network model
###############################################################################

variable "workers_per_node" {
  description = "mediasoup workers per node. Each owns one UDP and one TCP port; one per core."
  type        = number
  default     = 8

  validation {
    condition     = var.workers_per_node >= 1 && var.workers_per_node <= 64
    error_message = "workers_per_node must be between 1 and 64 (the WebRtcServer port scheme reserves 40000-40063)."
  }
}

variable "rtc_port_base" {
  description = "MEDIASOUP_RTC_PORT_BASE. Port for worker i is base + i, UDP and TCP. Changing this changes the published customer IP ranges."
  type        = number
  default     = 40000
}

variable "pipe_port_min" {
  description = "Node-to-node cascading, private IPs only, never announced"
  type        = number
  default     = 41000
}

variable "pipe_port_max" {
  type    = number
  default = 41999
}

variable "control_port" {
  description = "Private mTLS control RPC port, reachable from the realtime service only"
  type        = number
  default     = 7443
}

variable "enable_ipv6" {
  type    = bool
  default = false
}

###############################################################################
# Addressing and neighbours
###############################################################################

variable "eip_pool_tag" {
  description = "Tag value identifying this region's pre-allocated SFU Elastic IP pool"
  type        = string
}

variable "sfu_prefix_list_id" {
  description = "Managed prefix list of SFU public addresses; the TURN fleet relays only to these"
  type        = string
}

variable "turn_prefix_list_id" {
  description = "Managed prefix list of TURN public addresses; relayed media arrives from these"
  type        = string
}

variable "realtime_security_group_id" {
  description = "Security group of the realtime service, the only caller of the control port"
  type        = string
}

###############################################################################
# ECS
###############################################################################

variable "ecs_cluster_id" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "instance_profile_arn" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "enable_ecs_exec" {
  description = "Break-glass shell access. Audited; off outside incidents."
  type        = bool
  default     = false
}

###############################################################################
# Images
###############################################################################

variable "sfu_image_repository" {
  type = string
}

variable "sfu_image_digest" {
  description = "Immutable digest. Build once, promote the same digest through staging."
  type        = string

  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.sfu_image_digest))
    error_message = "sfu_image_digest must be a sha256 digest, not a tag."
  }
}

variable "capture_image_repository" {
  type = string
}

variable "capture_image_digest" {
  type = string

  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.capture_image_digest))
    error_message = "capture_image_digest must be a sha256 digest, not a tag."
  }
}

variable "release_sha" {
  type = string
}

###############################################################################
# Application wiring
###############################################################################

variable "redis_secret_arn" {
  description = "State cluster connection secret. The SFU receives state only, never the cache cluster."
  type        = string
}

variable "control_tls_secret_arn" {
  description = "mTLS cert, key and CA for the control RPC"
  type        = string
}

variable "recordings_bucket" {
  type = string
}

variable "recording_segment_seconds" {
  type    = number
  default = 6
}

###############################################################################
# Scaling thresholds
###############################################################################

variable "target_load_score" {
  description = "Fleet average the pool scales to. 0.60 leaves room for the ~3 min it takes a node to join."
  type        = number
  default     = 0.60
}

variable "cascade_threshold" {
  description = "Per-node score at which rooms start fanning out and capacity is added immediately"
  type        = number
  default     = 0.70
}

variable "max_load_score" {
  description = "Per-node cap. Above this, placement stops sending rooms to the node."
  type        = number
  default     = 0.85
}

variable "scale_in_load_score" {
  description = "Sustained fleet average below which one node is released through the drain"
  type    = number
  default = 0.30
}

variable "metric_namespace" {
  type    = string
  default = "Classroom/Media"
}

###############################################################################
# Lifecycle
###############################################################################

variable "launch_hook_timeout_seconds" {
  description = "Time allowed to attach an EIP and register the address. Failure abandons the instance."
  type        = number
  default     = 300
}

variable "drain_timeout_seconds" {
  description = "Maximum lesson length plus margin. A node still holding a room when this expires is terminated anyway."
  type        = number
  default     = 14400 # 4 h
}

variable "node_lifecycle_lambda_arn" {
  type = string
}

variable "node_lifecycle_lambda_name" {
  type = string
}

variable "node_lifecycle_dlq_arn" {
  type = string
}

variable "node_lifecycle_dlq_name" {
  type = string
}

###############################################################################
# Observability
###############################################################################

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "logs_kms_key_arn" {
  type = string
}

variable "ebs_kms_key_arn" {
  type = string
}

variable "log_level" {
  type    = string
  default = "info"
}

variable "pager_topic_arn" {
  type = string
}