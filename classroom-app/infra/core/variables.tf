// classroom-app/infra/core/variables.tf
/**
 * Core stack variables  (F7, F8)  [EXT]
 *
 * The control-plane stack: one region, its own state file. Media regions are
 * separate stacks (infra/media-edge) that read this stack's outputs through
 * remote state, which is why anything they need is both a variable here and an
 * output.
 *
 * Version 7 adds `media_regions` and `rtc_domain`. Everything that has to cross
 * the Transit Gateway — the realtime service reaching SFU control ports, media
 * nodes reaching the state Redis registry — is expressed as a CIDR, because a
 * security group reference cannot cross a region.
 */

variable "project" {
  description = "Name prefix for every resource in this stack."
  type        = string
  default     = "classroom"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project))
    error_message = "project must be lowercase letters, digits and dashes."
  }
}

variable "environment" {
  description = "Deployment environment. Selects sizes, retention and strictness."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "region" {
  description = "Control-plane region. Also the first media region in production."
  type        = string
  default     = "eu-central-1"
}

variable "vpc_cidr" {
  description = "CIDR of the control-plane VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "availability_zones" {
  description = "AZs to spread subnets and tasks across. Three in production."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "at least two availability zones are required."
  }
}

# ---------------------------------------------------------------------------
# DNS and certificates
# ---------------------------------------------------------------------------

variable "domain" {
  description = "Primary zone: app, api, ws, cdn and media records live here."
  type        = string
}

variable "rtc_domain" {
  description = <<-EOT
    [V7] Delegated zone for the media plane: turn-<region>-NN.<rtc_domain> per
    TURN node and turn-<region>.<rtc_domain> as the regional fallback. Managed
    by the node-lifecycle Lambda, and the name the TURN TLS certificate is
    issued for (*.<rtc_domain>, ACME DNS-01 — ACM cannot be installed on EC2).
  EOT
  type        = string
}

# ---------------------------------------------------------------------------
# Media regions
# ---------------------------------------------------------------------------

variable "media_regions" {
  description = <<-EOT
    [V7] Every region that runs SFU and TURN nodes. Each entry is a separate
    infra/media-edge stack with its own state; listing it here is what opens the
    control paths: realtime tasks reach SFU control ports, and media nodes reach
    the state Redis registry, both over the Transit Gateway.

    vpc_cidr is used for security group rules, because a security group
    reference does not cross a region — only CIDRs do.
  EOT
  type = list(object({
    region   = string
    vpc_cidr = string
    # Narrower than vpc_cidr where the private subnets are known: only these
    # addresses ever need to reach Redis or be reached on the control port.
    control_cidrs = optional(list(string), [])
    enabled       = optional(bool, true)
  }))

  validation {
    condition     = length(var.media_regions) > 0
    error_message = "at least one media region is required; the SFU has to live somewhere."
  }

  validation {
    condition = alltrue([
      for media_region in var.media_regions : can(cidrhost(media_region.vpc_cidr, 0))
    ])
    error_message = "every media region needs a valid vpc_cidr."
  }
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "api_service" {
  description = "Sizing for the stateless HTTP API."
  type = object({
    cpu           = optional(number, 512)
    memory        = optional(number, 1024)
    desired_count = optional(number, 3)
    min_count     = optional(number, 3)
    max_count     = optional(number, 20)
  })
  default = {}
}

variable "realtime_service" {
  description = <<-EOT
    [V7] Sizing for the realtime service: signalling, chat, presence and Yjs.
    Long-lived sockets, so it scales on connections and memory rather than CPU,
    and it is the only service allowed to reach SFU control ports.
  EOT
  type = object({
    cpu           = optional(number, 1024)
    memory        = optional(number, 2048)
    desired_count = optional(number, 3)
    min_count     = optional(number, 3)
    max_count     = optional(number, 30)
  })
  default = {}
}

variable "worker_service" {
  description = "Sizing for the BullMQ worker service."
  type = object({
    cpu           = optional(number, 1024)
    memory        = optional(number, 2048)
    desired_count = optional(number, 1)
    min_count     = optional(number, 1)
    max_count     = optional(number, 16)
  })
  default = {}
}

# ---------------------------------------------------------------------------
# Load balancer
# ---------------------------------------------------------------------------

variable "alb_idle_timeout_sec" {
  description = <<-EOT
    Must stay above the socket heartbeat (SOCKET_PING_INTERVAL_MS +
    SOCKET_PING_TIMEOUT_MS, 45 s by default) with room to spare, or the ALB
    closes idle WebSocket connections that are perfectly healthy and every quiet
    classroom reconnects for no reason.
  EOT
  type        = number
  default     = 300

  validation {
    condition     = var.alb_idle_timeout_sec >= 120 && var.alb_idle_timeout_sec <= 4000
    error_message = "alb_idle_timeout_sec must be between 120 and 4000 seconds."
  }
}

# ---------------------------------------------------------------------------
# Connectivity (F8)
# ---------------------------------------------------------------------------

variable "ice_credential_ttl_sec" {
  description = "Default TURN credential lifetime; tenants override within 1–24 h."
  type        = number
  default     = 28800

  validation {
    condition     = var.ice_credential_ttl_sec >= 3600 && var.ice_credential_ttl_sec <= 86400
    error_message = "ice_credential_ttl_sec must be between 1 and 24 hours."
  }
}

variable "turn_secret_rotation_days" {
  description = <<-EOT
    [V7] Rotation interval for the TURN shared secret ring. The rotation is
    three-phase (accept → sign → retire) and never breaks a live session; phase
    three waits out the maximum credential TTL, so this must stay well above it.
  EOT
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------

variable "database" {
  description = "RDS PostgreSQL. Multi-AZ and a read replica in production."
  type = object({
    instance_class          = optional(string, "db.t4g.medium")
    allocated_storage       = optional(number, 100)
    multi_az                = optional(bool, true)
    read_replica            = optional(bool, true)
    backup_retention_days   = optional(number, 14)
    deletion_protection     = optional(bool, true)
    performance_insights    = optional(bool, true)
  })
  default = {}
}

variable "redis_state" {
  description = <<-EOT
    State cluster: BullMQ, seat reservation, room and media-node registries,
    rate limits, session revocation. noeviction — it must never drop a key, and
    the alarm at 70 % memory exists for that reason.
  EOT
  type = object({
    node_type  = optional(string, "cache.t4g.medium")
    replicas   = optional(number, 1)
    shards     = optional(number, 1)
  })
  default = {}
}

variable "redis_cache" {
  description = "Cache cluster: entitlements, presence, unread counters, socket Pub/Sub. volatile-lru."
  type = object({
    node_type = optional(string, "cache.t4g.medium")
    replicas  = optional(number, 1)
    shards    = optional(number, 1)
  })
  default = {}
}

variable "opensearch" {
  description = "Search cluster for messages, community and profiles."
  type = object({
    enabled       = optional(bool, true)
    instance_type = optional(string, "t3.small.search")
    instance_count = optional(number, 2)
    volume_gb     = optional(number, 50)
  })
  default = {}
}

# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch log retention for every service in this stack."
  type        = number
  default     = 30
}

variable "alarm_emails" {
  description = "Addresses subscribed to the paging SNS topic."
  type        = list(string)
  default     = []
}

variable "github_repository" {
  description = "owner/name of the repository allowed to assume the OIDC deploy role."
  type        = string
}

variable "tags" {
  description = "Extra tags merged into every resource."
  type        = map(string)
  default     = {}
}