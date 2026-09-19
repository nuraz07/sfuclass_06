mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_iam_policy_document" { defaults = { json = "{}" } }
  mock_data "aws_ssm_parameter" { defaults = { value = "ami-0123" } }
  mock_data "aws_vpc" { defaults = { cidr_block = "10.65.0.0/16" } }
  mock_resource "aws_autoscaling_group" { defaults = { arn = "arn:aws:autoscaling:us-east-1:123456789012:autoScalingGroup:x:autoScalingGroupName/turn" } }
  mock_resource "aws_iam_instance_profile" { defaults = { arn = "arn:aws:iam::123456789012:instance-profile/p" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/r" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:g" } }
  mock_resource "aws_ecs_task_definition" { defaults = { arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/t:1" } }
}
variables {
  name_prefix                   = "classroom-prod"
  region                        = "us-east-1"
  region_short                  = "use1"
  vpc_id                        = "vpc-1"
  subnet_ids                    = ["subnet-a", "subnet-b", "subnet-c"]
  ecs_cluster                   = { name = "classroom-prod-media-us-east-1", arn = "arn:aws:ecs:us-east-1:123456789012:cluster/classroom-prod-media-us-east-1" }
  capacity_provider_association = "assoc"
  image                         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/classroom/turn:bootstrap"
  instance_types                = ["c7gn.xlarge", "c6gn.xlarge"]
  architecture                  = "arm64"
  realm                         = "rtc.example.com"
  min_nodes                     = 3
  max_nodes                     = 9
  capacity_mbps                 = 4000
  total_quota                   = 4000
  user_quota                    = 12
  max_bps                       = 0
  bps_capacity                  = 0
  relay_port_range              = { min = 49152, max = 65535 }
  target_load_ratio             = 0.6
  drain_timeout_minutes         = 240
  spot_allowed                  = false
  sfu_prefix_list_id            = "pl-sfu"
  sfu_rtc_port_range            = { min = 40000, max = 40063 }
  registry_cidr                 = "10.0.0.0/16"
  secret_arns                   = { turn_shared_secret = "arn:aws:secretsmanager:us-east-1:123456789012:secret:turn-AbCdEf", turn_tls = "arn:aws:secretsmanager:us-east-1:123456789012:secret:tls-AbCdEf", redis_state_url = "arn:aws:secretsmanager:us-east-1:123456789012:secret:redis-AbCdEf" }
  secrets_kms_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/k"
  logs_kms_key_arn              = "arn:aws:kms:us-east-1:123456789012:key/l"
  log_retention_days            = 90
  alarm_topic_arn               = "arn:aws:sns:us-east-1:123456789012:t"
}
run "unit" {
  command = plan
  assert {
    condition     = local.repository_arn == "arn:aws:ecr:us-east-1:123456789012:repository/classroom/turn" && local.image_tag == "bootstrap"
    error_message = "repository parsing"
  }
  assert {
    condition     = local.turn_env == "production"
    error_message = "TURN_ENV"
  }
  assert {
    condition     = aws_autoscaling_group.turn.max_size == 19 && aws_autoscaling_group.turn.protect_from_scale_in
    error_message = "asg sizing"
  }
  assert {
    condition     = aws_launch_template.turn.metadata_options[0].http_tokens == "required" && aws_launch_template.turn.metadata_options[0].instance_metadata_tags == "enabled"
    error_message = "IMDS"
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.turn.user_data), "net.ipv4.ip_local_port_range = 32768 49151") && strcontains(base64decode(aws_launch_template.turn.user_data), "ECS_CLUSTER=classroom-prod-media-us-east-1")
    error_message = "user data"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.turn.container_definitions)[0].command == ["coturn"] && jsondecode(aws_ecs_task_definition.turn.container_definitions)[1].command == ["agent"]
    error_message = "containers"
  }
  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.turn.container_definitions)[0].environment : "${e.name}=${e.value}"], "TURN_SECRET_ARN=arn:aws:secretsmanager:us-east-1:123456789012:secret:turn-AbCdEf")
    error_message = "coturn env"
  }
  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.turn.container_definitions)[1].environment : "${e.name}=${e.value}"], "TURN_DRAIN_TIMEOUT_MS=14400000")
    error_message = "agent env"
  }
  assert {
    condition     = aws_ecs_service.turn["blue"].desired_count == 3 && aws_ecs_service.turn["green"].desired_count == 0
    error_message = "colours"
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.relay_to_sfu.prefix_list_id == "pl-sfu" && aws_vpc_security_group_egress_rule.relay_to_sfu.to_port == 40063
    error_message = "relay egress"
  }
  assert {
    condition     = length([for h in aws_autoscaling_group.turn.initial_lifecycle_hook : h if h.default_result == "CONTINUE" && h.lifecycle_transition == "autoscaling:EC2_INSTANCE_TERMINATING"]) == 1
    error_message = "terminate hook"
  }
  assert {
    condition     = aws_appautoscaling_policy.turn_load["blue"].target_tracking_scaling_policy_configuration[0].disable_scale_in
    error_message = "scale-out only"
  }
}