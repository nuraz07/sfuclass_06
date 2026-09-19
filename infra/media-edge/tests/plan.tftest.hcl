mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_iam_policy_document" { defaults = { json = "{}" } }
  mock_data "aws_secretsmanager_secrets" { defaults = { arns = [] } }
  mock_resource "aws_eip" { defaults = { public_ip = "198.51.100.10", allocation_id = "eipalloc-1" } }
  mock_resource "aws_kms_key" { defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/k" } }
  mock_data "aws_ssm_parameter" { defaults = { value = "ami-0123456789abcdef0" } }
  mock_data "aws_vpc" { defaults = { cidr_block = "10.64.0.0/16" } }
  mock_resource "aws_autoscaling_group" { defaults = { arn = "arn:aws:autoscaling:us-east-1:123456789012:autoScalingGroup:x:autoScalingGroupName/turn" } }
  mock_resource "aws_lambda_function" { defaults = { arn = "arn:aws:lambda:us-east-1:123456789012:function:f" } }
  mock_resource "aws_sqs_queue" { defaults = { arn = "arn:aws:sqs:us-east-1:123456789012:q" } }
  mock_resource "aws_iam_instance_profile" { defaults = { arn = "arn:aws:iam::123456789012:instance-profile/p" } }
  mock_resource "aws_cloudwatch_event_rule" { defaults = { arn = "arn:aws:events:us-east-1:123456789012:rule/r" } }
  mock_resource "aws_ecs_task_definition" { defaults = { arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/t:1" } }
  mock_resource "aws_ecs_cluster" { defaults = { arn = "arn:aws:ecs:us-east-1:123456789012:cluster/c" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:g" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/r" } }
  mock_resource "aws_sns_topic" { defaults = { arn = "arn:aws:sns:us-east-1:123456789012:t" } }
}
mock_provider "aws" {
  alias = "core"
  mock_data "aws_ssm_parameters_by_path" {
    defaults = {
      names  = ["/classroom-prod/media/public-ips/us-east-1"]
      values = ["{\"region\":\"us-east-1\",\"sfu\":[\"3.3.3.3\",\"3.3.3.4\"],\"turn\":[\"3.3.3.9\"]}"]
    }
  }
}
override_data {
  target = data.terraform_remote_state.core
  values = {
    outputs = {
      transit_gateway_id                     = "tgw-hub"
      transit_gateway_region                 = "eu-central-1"
      transit_gateway_control_route_table_id = "tgw-rtb-control"
      transit_gateway_media_route_table_id   = "tgw-rtb-media"
      core_vpc_cidr                          = "10.0.0.0/16"
      media_edge_supernet                    = "10.64.0.0/10"
      rtc_domain                             = "rtc.example.com"
      rtc_zone_id                            = "Z123"
      turn_shared_secret_arn                 = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:classroom/turn-shared-AbCdEf"
      turn_tls_secret_arn                    = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:classroom/turn-tls-GhIjKl"
      redis_state_url_secret_arn             = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:classroom/redis-state-url-MnOpQr"
      sfu_control_node_tls_secret_arn        = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:classroom/sfu-node-tls-StUvWx"
      sfu_control_ca_secret_arn              = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:classroom/sfu-ca-YzAbCd"
      secrets_kms_key_arn                    = "arn:aws:kms:eu-central-1:123456789012:key/core-secrets"
      ecr_repository_names                   = { sfu = "classroom/sfu", capture = "classroom/capture", turn = "classroom/turn" }
    }
  }
}

run "plan" {
  command = plan
  # The replica check is expected to report here: the mocked account has no secrets. In a real plan it is a warning.
  expect_failures = [check.secret_replicas_present]

  assert {
    condition     = length(aws_eip.turn) == var.eip_pool.turn && length(aws_eip.sfu) == var.eip_pool.sfu
    error_message = "pool sizes"
  }
  assert {
    condition     = contains(keys(aws_eip.turn), format("turn-%s-01", var.region_short))
    error_message = "slot names"
  }
  assert {
    condition     = aws_eip.turn[format("turn-%s-01", var.region_short)].tags.TurnHostname == format("turn-%s-01.rtc.example.com", var.region_short)
    error_message = "hostname tag"
  }
  assert {
    condition     = var.region == "eu-central-1" ? local.replica_arns.turn_tls == "arn:aws:secretsmanager:eu-central-1:123456789012:secret:classroom/turn-tls-GhIjKl" : local.replica_arns.turn_tls == "arn:aws:secretsmanager:${var.region}:123456789012:secret:classroom/turn-tls-GhIjKl"
    error_message = "replica arn"
  }
  assert {
    condition     = var.region == "eu-central-1" ? length(aws_kms_key.secrets) == 0 : length(aws_kms_key.secrets) == 1
    error_message = "regional key only outside the core region"
  }
  assert {
    condition     = contains(local.global_sfu_ips, "3.3.3.3") && !contains(local.global_sfu_ips, "3.3.3.9")
    error_message = "global SFU list contains remote SFU but not TURN addresses"
  }
  assert {
    condition     = aws_ecs_cluster.media.name == "classroom-${var.environment}-media-${var.region}"
    error_message = "cluster name"
  }
  assert {
    condition     = local.turn_regional_fqdn == "turn-${var.region}.rtc.example.com"
    error_message = "regional name matches ice.config.js regionalHost()"
  }
  assert {
    condition     = length(aws_route53_record.turn_regional) == var.eip_pool.turn && alltrue([for r in aws_route53_record.turn_regional : r.multivalue_answer_routing_policy])
    error_message = "regional multivalue records"
  }
  assert {
    condition     = module.turn_pool.service_names == ["turn-blue", "turn-green"]
    error_message = "blue/green service names used by deploy-turn.yml"
  }
  assert {
    condition     = var.canary.enabled ? module.canary.alarm_name == "classroom-${var.environment}-turn-canary-${var.region}" : true
    error_message = "canary alarm name used by deploy-turn.yml"
  }
  assert {
    condition     = output.github_variables.TURN_CANARY_ALARM_PREFIX == "classroom-${var.environment}-turn-canary"
    error_message = "github variables"
  }
}