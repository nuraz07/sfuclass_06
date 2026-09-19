# infra/media-edge/variables.tf
#
# Inputs of one media-region stack. Values: infra/envs/<env>/media-edge.<region>.tfvars.
# Everything shared with the control plane (domains, secrets, repositories, Transit Gateway hub) is read from the
# core stack's remote state instead of being repeated here.
#
# Owner: F8 Real-Time Connectivity.

variable "environment" {
  description = "dev | staging | prod — must match the core stack of the same environment."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "region" {
  description = "AWS region of this media region, e.g. eu-central-1."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]{1,2}$", var.region))
    error_message = "region must be an AWS region code."
  }
}

variable "region_short" {
  description = "Short region code used in node and DNS names, e.g. euc1 → turn-euc1-07."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,6}$", var.region_short))
    error_message = "region_short must be 3-6 lowercase letters or digits."
  }
}

variable "availability_zone_ids" {
  description = "AZ IDs (e.g. euc1-az1) for the subnets; IDs are identical across accounts, names are not."
  type        = list(string)

  validation {
    condition     = length(var.availability_zone_ids) >= 1 && length(var.availability_zone_ids) <= 3 && alltrue([for z in var.availability_zone_ids : can(regex("^[a-z0-9]+-az[0-9]+$", z))])
    error_message = "availability_zone_ids must contain 1-3 AZ IDs such as euc1-az1."
  }
}

variable "vpc_cidr" {
  description = "VPC CIDR of this region; a /16 inside the core's media_edge_supernet, unique per region."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 18
    error_message = "vpc_cidr must be a valid IPv4 CIDR of /18 or larger."
  }
}

variable "transit_gateway_asn" {
  description = "Private ASN of this region's Transit Gateway; unique per region and different from the hub."
  type        = number

  validation {
    condition     = (var.transit_gateway_asn >= 64512 && var.transit_gateway_asn <= 65534) || (var.transit_gateway_asn >= 4200000000 && var.transit_gateway_asn <= 4294967294)
    error_message = "transit_gateway_asn must be a private ASN."
  }
}

variable "core_remote_state" {
  description = "Where the core stack of the same environment keeps its state (read-only access)."
  type = object({
    bucket         = string
    key            = string
    region         = string
    dynamodb_table = optional(string)
  })
}

variable "sfu" {
  description = "SFU node pool (infra/modules/sfu-node-pool)."
  type = object({
    instance_types        = list(string)
    architecture          = string
    workers               = number
    rtc_port_base         = number
    pipe_port_range       = object({ min = number, max = number })
    control_port          = number
    min_nodes             = number
    max_nodes             = number
    target_load_score     = number
    max_load_score        = number
    consumers_per_worker  = number
    egress_capacity_mbps  = number
    drain_timeout_minutes = number
    spot_allowed          = bool
    ipv6                  = bool
  })

  validation {
    condition = (
      var.sfu.min_nodes >= 1 && var.sfu.max_nodes >= var.sfu.min_nodes &&
      var.sfu.workers >= 1 && var.sfu.workers <= 64 &&
      var.sfu.rtc_port_base >= 1024 && var.sfu.rtc_port_base + var.sfu.workers - 1 < var.sfu.pipe_port_range.min &&
      var.sfu.pipe_port_range.min <= var.sfu.pipe_port_range.max && var.sfu.pipe_port_range.max <= 49151 &&
      var.sfu.target_load_score < var.sfu.max_load_score && var.sfu.max_load_score <= 1 &&
      contains(["arm64", "x86_64"], var.sfu.architecture) && length(var.sfu.instance_types) >= 1 &&
      var.sfu.drain_timeout_minutes >= 5 && var.sfu.drain_timeout_minutes <= 1440
    )
    error_message = "sfu: check node counts, worker/port layout (rtc ports below the pipe range, pipe range below 49152), load scores and drain timeout."
  }
}

variable "turn" {
  description = "TURN node pool (infra/modules/turn-node-pool, coturn + agent)."
  type = object({
    instance_types        = list(string)
    architecture          = string
    min_nodes             = number
    max_nodes             = number
    capacity_mbps         = number
    total_quota           = number
    user_quota            = number
    max_bps               = number
    bps_capacity          = number
    relay_port_range      = object({ min = number, max = number })
    target_load_ratio     = number
    drain_timeout_minutes = number
    spot_allowed          = bool
  })

  validation {
    condition = (
      var.turn.min_nodes >= 1 && var.turn.max_nodes >= var.turn.min_nodes && var.turn.max_nodes <= 99 &&
      var.turn.relay_port_range.min >= 49152 && var.turn.relay_port_range.max <= 65535 &&
      var.turn.relay_port_range.min < var.turn.relay_port_range.max &&
      var.turn.drain_timeout_minutes >= 5 && var.turn.drain_timeout_minutes <= 360 &&
      contains(["arm64", "x86_64"], var.turn.architecture) && length(var.turn.instance_types) >= 1
    )
    error_message = "turn: check node counts (max 99, two-digit node names), relay port range (49152-65535) and drain timeout (<= 6 h, the deploy job limit)."
  }
}

variable "eip_pool" {
  description = "Pre-allocated Elastic IPs per pool. Published for customer allowlists: grow ahead of need, never shrink silently."
  type = object({
    sfu              = number
    turn             = number
    public_ipv4_pool = optional(string)
  })
}

variable "canary" {
  description = "CloudWatch Synthetics TURN canary of this region."
  type = object({
    enabled  = bool
    schedule = string
  })
}

variable "log_retention_days" {
  description = "Retention of every log group of this stack."
  type        = number

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs accepts."
  }
}

variable "alarm_topic_name" {
  description = "Base name of the alarm topic; this region gets <name>-media-<region_short> (alarms need a topic in their own region)."
  type        = string
}

variable "alarm_subscriptions" {
  description = "Subscriptions of the regional alarm topic, e.g. [{ protocol = \"https\", endpoint = \"https://events.pagerduty.com/…\" }]."
  type = list(object({
    protocol = string
    endpoint = string
  }))
  default = []
}

variable "initial_image_tag" {
  description = "Image tag for the first task definition revisions only; deploy-sfu.yml / deploy-turn.yml own the images afterwards."
  type        = string
  default     = "bootstrap"
}

variable "sfu_global_prefix_list_capacity" {
  description = "max_entries of the prefix list holding the SFU addresses of ALL media regions. Counts against the security-group rule quota of every group that references it."
  type        = number
  default     = 100
}

variable "tags" {
  description = "Extra tags for every resource (merged into provider default_tags)."
  type        = map(string)
  default     = {}
}