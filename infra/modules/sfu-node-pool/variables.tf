# infra/modules/sfu-node-pool/variables.tf
#
# Interface of the SFU node pool, as called by infra/media-edge/main.tf (module "sfu_pool").
# Replaces the v6 file infra/ecs-sfu.tf (SFU behind an NLB on a UDP port range).
#
# Owner: F1 Live Classrooms + F8 Real-Time Connectivity.

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
  description = "ID of aws_ecs_cluster_capacity_providers in the root module; services are created after it."
  type        = string
}

variable "images" {
  description = "Images in the regional ECR replica: sfu (Dockerfile.sfu) and capture (Dockerfile.capture). deploy-sfu.yml owns them after the first apply."
  type = object({
    sfu     = string
    capture = string
  })
}

variable "instance_types" {
  description = "Instance types in order of preference (mixed-instances policy)."
  type        = list(string)
}

variable "architecture" {
  description = "arm64 or x86_64; must match the instance types and the images."
  type        = string

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "ipv6" {
  description = "Open the media ports for IPv6 too (dual-stack subnets)."
  type        = bool
}

variable "workers" {
  description = "mediasoup workers per node; one WebRtcServer (UDP + TCP port) each."
  type        = number
}

variable "rtc_port_base" {
  description = "WebRtcServer ports are rtc_port_base .. rtc_port_base + workers - 1 (UDP and TCP)."
  type        = number
}

variable "pipe_port_range" {
  description = "Pipe transports between SFU nodes of this region (private IPs only)."
  type        = object({ min = number, max = number })
}

variable "control_port" {
  description = "Control RPC port (mTLS) on the node's private IP."
  type        = number
}

variable "control_ingress_cidr" {
  description = "Where the realtime service calls from (core VPC CIDR, over the Transit Gateway); also where the state Redis lives."
  type        = string
}

variable "min_nodes" {
  description = "Nodes at creation and the floor of the active colour."
  type        = number
}

variable "max_nodes" {
  description = "Upper bound of the active colour; the Auto Scaling group allows 2 x max_nodes + 1 during blue/green switches."
  type        = number
}

variable "target_load_score" {
  description = "Scale-out target for Classroom/Sfu LoadScore (region average)."
  type        = number
}

variable "max_load_score" {
  description = "Load score above which a node reports unhealthy (SFU_MAX_LOAD_SCORE)."
  type        = number
}

variable "consumers_per_worker" {
  description = "Planned consumers per mediasoup worker (LoadReporter capacity)."
  type        = number
}

variable "egress_capacity_mbps" {
  description = "Planned egress per node in Mbit/s (LoadReporter capacity)."
  type        = number
}

variable "drain_timeout_minutes" {
  description = "Upper bound for rooms to end before a draining node is stopped."
  type        = number
}

variable "spot_allowed" {
  description = "Allow Spot capacity (development only: an interruption ends every room on the node)."
  type        = bool
}

variable "secret_arns" {
  description = "Secrets as readable in this region (replicas outside the core region)."
  type = object({
    redis_state_url = string
    control_tls     = string # {"cert": "...", "key": "..."} — SAN sfu.control.internal
    control_ca      = string
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
  description = "Retention of the SFU log group."
  type        = number
}

variable "alarm_topic_arn" {
  description = "Regional alarm topic."
  type        = string
}

variable "recordings_bucket_arn" {
  description = "S3 bucket for recording segments (core media.tf). Null: recording uploads are not permitted from this region."
  type        = string
  default     = null
}

variable "capture_rtp_port_range" {
  description = "Loopback RTP ports of the capture sidecar (CAPTURE_RTP_PORT_MIN/MAX)."
  type        = object({ min = number, max = number })
  default     = { min = 45000, max = 45999 }
}

variable "redis_cluster_mode" {
  description = "State Redis runs in cluster mode."
  type        = bool
  default     = false
}

variable "root_volume_gb" {
  description = "Root volume size; also holds the capture scratch volume."
  type        = number
  default     = 60
}

variable "service_base" {
  description = "ECS services are <service_base>-blue and <service_base>-green."
  type        = string
  default     = "sfu"
}