# infra/modules/node-lifecycle/variables.tf
#
# Interface of the node-lifecycle function, as called by infra/media-edge/main.tf (module "node_lifecycle").
#
# Owner: F8 Real-Time Connectivity.

variable "name_prefix" {
  description = "Resource name prefix of the environment, e.g. classroom-prod."
  type        = string
}

variable "region" {
  description = "Media region."
  type        = string
}

variable "vpc_id" {
  description = "Media VPC (the function runs in its private subnets)."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets: AWS APIs through VPC endpoints, state Redis through the Transit Gateway."
  type        = list(string)
}

variable "pools" {
  description = "Node pools handled by this function, keyed by kind (sfu, turn)."
  type = map(object({
    asg_name              = string
    asg_arn               = string
    launch_hook_name      = string
    terminate_hook_name   = string
    eip_allocation_ids    = list(string)
    node_tags             = bool
    drain_timeout_minutes = optional(number, 240)
  }))

  validation {
    condition     = alltrue([for k in keys(var.pools) : contains(["sfu", "turn"], k)])
    error_message = "pools keys must be sfu and/or turn (the handler derives node names from the kind)."
  }
}

variable "ecs_cluster_name" {
  description = "ECS cluster of the pools; default follows the media-edge naming <name_prefix>-media-<region>."
  type        = string
  default     = null
}

variable "redis_state_url_secret_arn" {
  description = "Secret with the state Redis URL (regional replica)."
  type        = string
}

variable "redis_cluster_mode" {
  description = "State Redis runs in cluster mode."
  type        = bool
  default     = false
}

variable "secrets_kms_key_arn" {
  description = "KMS key of the secrets in this region."
  type        = string
}

variable "logs_kms_key_arn" {
  description = "KMS key for the log group and the dead-letter queue."
  type        = string
}

variable "log_retention_days" {
  description = "Retention of the function's log group."
  type        = number
}

variable "alarm_topic_arn" {
  description = "Regional alarm topic (function errors, dead letters)."
  type        = string
}

variable "metrics_namespace" {
  description = "Namespace of the FreeEips metric."
  type        = string
  default     = "Classroom/MediaEdge"
}

variable "artifact_dir" {
  description = "Directory with the bundled handler (index.mjs), produced by `npm run build:node-lifecycle` in infra/functions."
  type        = string
  default     = null
}