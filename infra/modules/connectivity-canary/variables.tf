# infra/modules/connectivity-canary/variables.tf
#
# Interface of the TURN canary, as called by infra/media-edge/main.tf (module "canary").
#
# Owner: F8 Real-Time Connectivity.

variable "name_prefix" {
  description = "Resource name prefix of the environment, e.g. classroom-prod."
  type        = string
}

variable "region" {
  description = "Media region the canary tests."
  type        = string
}

variable "enabled" {
  description = "Run the canary. When false it is created but stopped, and no alarm exists."
  type        = bool
}

variable "schedule" {
  description = "Synthetics schedule expression, e.g. rate(1 minute)."
  type        = string

  validation {
    condition     = can(regex("^(rate\\(.+\\)|cron\\(.+\\))$", var.schedule))
    error_message = "schedule must be a rate() or cron() expression."
  }
}

variable "regional_host" {
  description = "Health-checked regional TURN name, turn-<region>.<rtc_domain>."
  type        = string
}

variable "realm" {
  description = "TURN realm (rtc domain)."
  type        = string
}

variable "turn_secret_arn" {
  description = "TURN shared secret as readable in this region; the canary mints its own short-lived credential."
  type        = string
}

variable "secrets_kms_key_arn" {
  description = "KMS key of the secrets in this region."
  type        = string
}

variable "logs_kms_key_arn" {
  description = "KMS key for the canary's logs and artifacts."
  type        = string
}

variable "log_retention_days" {
  description = "Retention of the canary's log group and artifacts."
  type        = number
}

variable "alarm_topic_arn" {
  description = "Regional alarm topic."
  type        = string
}

variable "alarm_name" {
  description = "Alarm name; deploy-turn.yml reads <TURN_CANARY_ALARM_PREFIX>-<region>."
  type        = string
}

variable "runtime_version" {
  description = "CloudWatch Synthetics Node.js runtime. Keep on a supported version (see the Synthetics runtime list)."
  type        = string
  default     = "syn-nodejs-puppeteer-9.1"
}

variable "probe_peer_ip" {
  description = "Public IPv4 used for the permission test (no traffic is sent to it)."
  type        = string
  default     = "1.1.1.1"
}

variable "failed_runs_to_alarm" {
  description = "Consecutive failed minutes before the alarm fires."
  type        = number
  default     = 2
}

variable "artifact_dir" {
  description = "Directory with nodejs/node_modules/canary.js, produced by `npm run build:turn-canary` in infra/functions."
  type        = string
  default     = null
}