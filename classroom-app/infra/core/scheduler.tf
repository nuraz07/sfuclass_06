# infra/core/scheduler.tf
#
# EventBridge Scheduler for the periodic jobs in server/src/jobs/ (architecture doc, section 7: "Scheduled jobs").
# Moved out of observability.tf in v7: scheduling is not observability.
#
# Each schedule starts ONE one-off ECS task from the worker task definition family — the same image, secrets,
# roles and network as the worker service — with the container command overridden to run a single job:
#
#   node --import ./src/observability/tracing.js ./src/jobs/<job>.js
#
# The family is referenced without a revision, so every run uses the latest ACTIVE revision, i.e. the image the
# last deployment registered. No separate job image or task definition has to be kept in sync.
#
# Guarantees:
#   single runner  every job takes a Redis lock (jobs are leader-elected in code); a late or duplicate start is a
#                  no-op, never a second concurrent run
#   retries        two retries within one hour, then the event goes to the dead-letter queue (alarmed in
#                  observability.tf on ApproximateNumberOfMessagesVisible > 0)
#   cost           jobs are idempotent and short, so they prefer FARGATE_SPOT and fall back to FARGATE
#   time zone      cron expressions are evaluated in var.jobs_timezone (DST-safe); per-tenant local times
#                  (daily digest) are resolved inside the job, which therefore runs hourly
#
# Contract with other files of this stack:
#   ecs-cluster.tf      aws_ecs_cluster.main (FARGATE and FARGATE_SPOT capacity providers)
#   ecs-worker.tf       aws_ecs_task_definition.worker (container named "worker") · aws_iam_role.worker_task ·
#                       aws_iam_role.worker_execution
#   security-groups.tf  aws_security_group.worker
#   network.tf          aws_subnet.private (for_each AZ)
#   kms.tf              aws_kms_key.logs (also used for the dead-letter queue)
#   locals.tf           local.name_prefix
#
# Owner: F7 Production and Operations.

variable "jobs_timezone" {
  description = "IANA time zone for the cron expressions below."
  type        = string
  default     = "Europe/Berlin"
}

variable "jobs" {
  description = "Scheduled jobs: file in server/src/jobs/, schedule expression, task size, flexible window (0 = exact) and on/off."
  type = map(object({
    file               = string
    schedule           = string
    cpu                = optional(number, 512)
    memory             = optional(number, 1024)
    flexible_window_mn = optional(number, 0)
    enabled            = optional(bool, true)
  }))
  default = {
    "check-expired-subscriptions" = { file = "checkExpiredSubscriptions.js", schedule = "rate(15 minutes)" }
    "reconcile-transcodes"        = { file = "reconcileTranscodes.js", schedule = "rate(10 minutes)" }
    "digest-notifications"        = { file = "digestNotifications.js", schedule = "cron(5 * * * ? *)" }
    "recompute-storage-usage"     = { file = "recomputeStorageUsage.js", schedule = "cron(30 2 * * ? *)", cpu = 1024, memory = 2048, flexible_window_mn = 30 }
    "prune-chat-retention"        = { file = "pruneChatRetention.js", schedule = "cron(0 3 * * ? *)", flexible_window_mn = 30 }
    "prune-recordings"            = { file = "pruneRecordings.js", schedule = "cron(30 3 * * ? *)", flexible_window_mn = 30 }
  }

  validation {
    condition = alltrue([
      for job in values(var.jobs) :
      can(regex("^[A-Za-z][A-Za-z0-9]*\\.js$", job.file)) && can(regex("^(rate|cron|at)\\(.+\\)$", job.schedule))
    ])
    error_message = "Each job needs a plain file name in server/src/jobs/ (e.g. pruneRecordings.js) and a rate(), cron() or at() expression."
  }

  validation {
    condition = alltrue([
      for job in values(var.jobs) :
      contains([256, 512, 1024, 2048, 4096], job.cpu) && job.memory >= 512 && job.flexible_window_mn >= 0 && job.flexible_window_mn <= 1440
    ])
    error_message = "cpu must be a Fargate size (256-4096), memory >= 512 MiB, flexible_window_mn between 0 and 1440."
  }
}

locals {
  jobs_group_name = "${local.name_prefix}-jobs"
  # Family ARN without revision: RunTask uses the latest ACTIVE revision (the currently deployed worker image).
  worker_family_arn = "arn:${data.aws_partition.scheduler.partition}:ecs:${data.aws_region.scheduler.id}:${data.aws_caller_identity.scheduler.account_id}:task-definition/${aws_ecs_task_definition.worker.family}"
}

data "aws_partition" "scheduler" {}
data "aws_region" "scheduler" {}
data "aws_caller_identity" "scheduler" {}

resource "aws_scheduler_schedule_group" "jobs" {
  name = local.jobs_group_name
}

# ------------------------------------------------------------------ dead-letter queue

resource "aws_sqs_queue" "jobs_dlq" {
  name                              = "${local.jobs_group_name}-dlq"
  message_retention_seconds         = 1209600 # 14 days: enough to investigate and replay
  kms_master_key_id                 = aws_kms_key.logs.arn
  kms_data_key_reuse_period_seconds = 3600
}

data "aws_iam_policy_document" "jobs_dlq" {
  statement {
    sid       = "SchedulerDeadLetters"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs_dlq.arn]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.scheduler.partition}:scheduler:${data.aws_region.scheduler.id}:${data.aws_caller_identity.scheduler.account_id}:schedule/${local.jobs_group_name}/*"]
    }
  }
}

resource "aws_sqs_queue_policy" "jobs_dlq" {
  queue_url = aws_sqs_queue.jobs_dlq.id
  policy    = data.aws_iam_policy_document.jobs_dlq.json
}

# ------------------------------------------------------------------ scheduler role

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.scheduler.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.jobs_group_name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "RunJobTasks"
    actions   = ["ecs:RunTask"]
    resources = ["${local.worker_family_arn}:*", local.worker_family_arn]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.main.arn]
    }
  }
  statement {
    sid       = "TagJobTasks"
    actions   = ["ecs:TagResource"]
    resources = ["arn:${data.aws_partition.scheduler.partition}:ecs:${data.aws_region.scheduler.id}:${data.aws_caller_identity.scheduler.account_id}:task/${aws_ecs_cluster.main.name}/*"]
    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RunTask"]
    }
  }
  statement {
    sid       = "PassWorkerRoles"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.worker_task.arn, aws_iam_role.worker_execution.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
  statement {
    sid       = "DeadLetters"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs_dlq.arn]
  }
  statement {
    sid       = "EncryptDeadLetters"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.logs.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "run-jobs"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

# ------------------------------------------------------------------ schedules

resource "aws_scheduler_schedule" "job" {
  for_each = var.jobs

  name                         = each.key
  group_name                   = aws_scheduler_schedule_group.jobs.name
  description                  = "Runs server/src/jobs/${each.value.file} as a one-off ECS task"
  schedule_expression          = each.value.schedule
  schedule_expression_timezone = var.jobs_timezone
  state                        = each.value.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode                      = each.value.flexible_window_mn > 0 ? "FLEXIBLE" : "OFF"
    maximum_window_in_minutes = each.value.flexible_window_mn > 0 ? each.value.flexible_window_mn : null
  }

  target {
    arn      = aws_ecs_cluster.main.arn
    role_arn = aws_iam_role.scheduler.arn

    # Task overrides for the RunTask call: run exactly one job in the worker container, sized per job.
    input = jsonencode({
      cpu    = tostring(each.value.cpu)
      memory = tostring(each.value.memory)
      containerOverrides = [{
        name    = "worker"
        command = ["node", "--import", "./src/observability/tracing.js", "./src/jobs/${each.value.file}"]
        environment = [
          { name = "JOB_NAME", value = each.key },
          { name = "SERVICE_ROLE", value = "job" },
        ]
      }]
    })

    ecs_parameters {
      task_definition_arn     = local.worker_family_arn
      task_count              = 1
      enable_ecs_managed_tags = true
      propagate_tags          = "TASK_DEFINITION"
      group                   = "job:${each.key}"
      tags = {
        job = each.key
      }

      capacity_provider_strategy {
        capacity_provider = "FARGATE_SPOT"
        weight            = 3
      }
      capacity_provider_strategy {
        capacity_provider = "FARGATE"
        base              = 0
        weight            = 1
      }

      network_configuration {
        subnets          = [for subnet in aws_subnet.private : subnet.id]
        security_groups  = [aws_security_group.worker.id]
        assign_public_ip = false
      }
    }

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 3600
    }

    dead_letter_config {
      arn = aws_sqs_queue.jobs_dlq.arn
    }
  }

  depends_on = [aws_iam_role_policy.scheduler, aws_sqs_queue_policy.jobs_dlq]
}

# ------------------------------------------------------------------ outputs

output "jobs_schedule_group" {
  description = "EventBridge Scheduler group holding all job schedules."
  value       = aws_scheduler_schedule_group.jobs.name
}

output "jobs_dead_letter_queue_arn" {
  description = "Dead-letter queue for job invocations that failed after retries (alarmed in observability.tf)."
  value       = aws_sqs_queue.jobs_dlq.arn
}