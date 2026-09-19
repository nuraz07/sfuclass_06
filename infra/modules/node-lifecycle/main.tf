# infra/modules/node-lifecycle/main.tf
#
# Runs infra/functions/node-lifecycle/handler.js for one media region:
#
#   EventBridge rule "lifecycle"  Auto Scaling launch/terminate lifecycle actions of the pools' groups → function
#   EventBridge rule "metrics"    every 5 minutes → function (FreeEips per pool)
#   function                      Node.js 22, arm64, in the private subnets of the media VPC
#   dead letters                  one encrypted SQS queue for EventBridge delivery failures and failed async invocations
#   alarms                        function errors · dead letters present
#
# Code: the bundle from infra/functions (`npm ci && npm run build` in CI before `tofu plan`), zipped here.
#
# Owner: F8 Real-Time Connectivity.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4, < 3.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name         = "${var.name_prefix}-node-lifecycle-${var.region}"
  function     = substr(local.name, 0, 64)
  partition    = data.aws_partition.current.partition
  account_id   = data.aws_caller_identity.current.account_id
  cluster_name = coalesce(var.ecs_cluster_name, "${var.name_prefix}-media-${var.region}")
  artifact_dir = coalesce(var.artifact_dir, "${path.module}/../../functions/dist/node-lifecycle")

  # Shape expected by the handler (loadPools).
  pools_env = {
    for kind, p in var.pools : kind => {
      asgName             = p.asg_name
      launchHookName      = p.launch_hook_name
      terminateHookName   = p.terminate_hook_name
      allocationIds       = p.eip_allocation_ids
      nodeTags            = p.node_tags
      drainTimeoutMinutes = p.drain_timeout_minutes
    }
  }
}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = local.artifact_dir
  output_path = "${path.root}/.build/${local.function}.zip"
}

# ------------------------------------------------------------------ logs and dead letters

resource "aws_cloudwatch_log_group" "function" {
  name              = "/aws/lambda/${local.function}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_kms_key_arn
}

resource "aws_sqs_queue" "dead_letters" {
  name                              = "${local.function}-dlq"
  message_retention_seconds         = 1209600
  kms_master_key_id                 = var.logs_kms_key_arn
  kms_data_key_reuse_period_seconds = 3600
}

data "aws_iam_policy_document" "dead_letters" {
  statement {
    sid       = "EventBridgeDeliveryFailures"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dead_letters.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:events:${var.region}:${local.account_id}:rule/${local.function}-*"]
    }
  }
}

resource "aws_sqs_queue_policy" "dead_letters" {
  queue_url = aws_sqs_queue.dead_letters.id
  policy    = data.aws_iam_policy_document.dead_letters.json
}

# ------------------------------------------------------------------ network

resource "aws_security_group" "function" {
  name        = local.function
  description = "node-lifecycle function: AWS APIs (VPC endpoints) and state Redis only"
  vpc_id      = var.vpc_id

  tags = {
    Name = local.function
  }
}

# The private subnets have no internet route: 443 reaches the VPC endpoints, 6379 the core VPC over the Transit Gateway.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.function.id
  description       = "AWS APIs through VPC endpoints"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "redis" {
  security_group_id = aws_security_group.function.id
  description       = "State Redis (drain flags)"
  ip_protocol       = "tcp"
  from_port         = 6379
  to_port           = 6379
  cidr_ipv4         = "0.0.0.0/0"
}

# ------------------------------------------------------------------ IAM

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "function" {
  name               = local.function
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.function.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "function" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.function.arn}:*"]
  }

  statement {
    sid       = "DescribeAddressesAndInstances"
    actions   = ["ec2:DescribeAddresses", "ec2:DescribeInstances"]
    resources = ["*"] # Describe actions do not support resource-level permissions
  }

  statement {
    sid     = "AssociatePoolAddresses"
    actions = ["ec2:AssociateAddress"]
    resources = [
      for id in flatten([for p in var.pools : p.eip_allocation_ids]) :
      "arn:${local.partition}:ec2:${var.region}:${local.account_id}:elastic-ip/${id}"
    ]
  }

  statement {
    sid       = "AssociateToPoolInstances"
    actions   = ["ec2:AssociateAddress"]
    resources = ["arn:${local.partition}:ec2:${var.region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/aws:autoscaling:groupName"
      values   = [for p in var.pools : p.asg_name]
    }
  }

  statement {
    sid       = "AssociateOnNetworkInterfaces"
    actions   = ["ec2:AssociateAddress"]
    resources = ["arn:${local.partition}:ec2:${var.region}:${local.account_id}:network-interface/*"]
  }

  statement {
    sid       = "TagPoolInstances"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:${var.region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/aws:autoscaling:groupName"
      values   = [for p in var.pools : p.asg_name]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["TurnNodeName", "TurnHostname", "TurnPublicIp", "SfuSlot", "SfuPublicIp"]
    }
  }

  statement {
    sid       = "CompleteLifecycleActions"
    actions   = ["autoscaling:CompleteLifecycleAction"]
    resources = [for p in var.pools : p.asg_arn]
  }

  statement {
    sid       = "ListContainerInstances"
    actions   = ["ecs:ListContainerInstances"]
    resources = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:cluster/${local.cluster_name}"]
  }

  statement {
    sid       = "DescribeContainerInstances"
    actions   = ["ecs:DescribeContainerInstances"]
    resources = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:container-instance/${local.cluster_name}/*"]
  }

  statement {
    sid       = "RedisUrl"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.redis_state_url_secret_arn]
  }

  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [var.secrets_kms_key_arn]
  }

  statement {
    sid       = "DeadLetters"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dead_letters.arn]
  }

  statement {
    sid       = "EncryptDeadLetters"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.logs_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "function" {
  name   = "node-lifecycle"
  role   = aws_iam_role.function.id
  policy = data.aws_iam_policy_document.function.json
}

# ------------------------------------------------------------------ function

resource "aws_lambda_function" "node_lifecycle" {
  function_name    = local.function
  description      = "EIP attach + drain flags for SFU/TURN nodes in ${var.region}"
  role             = aws_iam_role.function.arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256
  memory_size      = 256
  timeout          = 300 # waits for the instance to run (up to 180 s) before associating the address

  environment {
    variables = {
      POOLS                = jsonencode(local.pools_env)
      ECS_CLUSTER          = local.cluster_name
      REDIS_URL_SECRET_ARN = var.redis_state_url_secret_arn
      REDIS_CLUSTER        = var.redis_cluster_mode ? "true" : "false"
      METRICS_NAMESPACE    = var.metrics_namespace
      NODE_OPTIONS         = "--enable-source-maps"
    }
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.function.id]
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dead_letters.arn
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.function.name
  }

  depends_on = [aws_iam_role_policy.function, aws_iam_role_policy_attachment.vpc_access]
}

resource "aws_lambda_function_event_invoke_config" "node_lifecycle" {
  function_name                = aws_lambda_function.node_lifecycle.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600
}

# ------------------------------------------------------------------ EventBridge

resource "aws_cloudwatch_event_rule" "lifecycle" {
  name        = "${local.function}-hooks"
  description = "Auto Scaling lifecycle actions of the media node pools"
  event_pattern = jsonencode({
    source        = ["aws.autoscaling"]
    "detail-type" = ["EC2 Instance-launch Lifecycle Action", "EC2 Instance-terminate Lifecycle Action"]
    detail = {
      AutoScalingGroupName = [for p in var.pools : p.asg_name]
    }
  })
}

resource "aws_cloudwatch_event_rule" "metrics" {
  name                = "${local.function}-metrics"
  description         = "Refresh FreeEips metrics of the media node pools"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "lifecycle" {
  rule = aws_cloudwatch_event_rule.lifecycle.name
  arn  = aws_lambda_function.node_lifecycle.arn

  retry_policy {
    maximum_retry_attempts       = 10
    maximum_event_age_in_seconds = 900
  }

  dead_letter_config {
    arn = aws_sqs_queue.dead_letters.arn
  }
}

resource "aws_cloudwatch_event_target" "metrics" {
  rule  = aws_cloudwatch_event_rule.metrics.name
  arn   = aws_lambda_function.node_lifecycle.arn
  input = jsonencode({ action = "metrics" })

  dead_letter_config {
    arn = aws_sqs_queue.dead_letters.arn
  }
}

resource "aws_lambda_permission" "events" {
  for_each = {
    lifecycle = aws_cloudwatch_event_rule.lifecycle.arn
    metrics   = aws_cloudwatch_event_rule.metrics.arn
  }

  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.node_lifecycle.function_name
  principal     = "events.amazonaws.com"
  source_arn    = each.value
}

# ------------------------------------------------------------------ alarms

resource "aws_cloudwatch_metric_alarm" "errors" {
  alarm_name          = "${local.function}-errors"
  alarm_description   = "node-lifecycle failed: nodes may launch without an Elastic IP or never drain. Runbook: ops/runbooks/turn-incident.md, sfu-incident.md"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.node_lifecycle.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "dead_letters" {
  alarm_name          = "${local.function}-dead-letters"
  alarm_description   = "Lifecycle events that could not be handled after all retries. Inspect the queue, then complete or abandon the affected lifecycle actions by hand."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dead_letters.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}

# ------------------------------------------------------------------ outputs

output "function_arn" {
  description = "ARN of the node-lifecycle function."
  value       = aws_lambda_function.node_lifecycle.arn
}

output "dead_letter_queue_arn" {
  description = "Dead-letter queue of the function."
  value       = aws_sqs_queue.dead_letters.arn
}