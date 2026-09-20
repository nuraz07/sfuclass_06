# infra/modules/sfu-node-pool/tests/unit.tftest.hcl — plan-level checks with a mocked AWS provider (tofu test).
mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_iam_policy_document" { defaults = { json = "{}" } }
  mock_data "aws_ssm_parameter" { defaults = { value = "ami-0123" } }
  mock_data "aws_vpc" { defaults = { cidr_block = "10.64.0.0/16" } }
  mock_resource "aws_autoscaling_group" { defaults = { arn = "arn:aws:autoscaling:eu-central-1:123456789012:autoScalingGroup:x:autoScalingGroupName/sfu" } }
  mock_resource "aws_iam_instance_profile" { defaults = { arn = "arn:aws:iam::123456789012:instance-profile/p" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/r" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:eu-central-1:123456789012:log-group:g" } }
  mock_resource "aws_ecs_task_definition" { defaults = { arn = "arn:aws:ecs:eu-central-1:123456789012:task-definition/t:1" } }
}

variables {
  name_prefix                   = "classroom-prod"
  region                        = "eu-central-1"
  region_short                  = "euc1"
  vpc_id                        = "vpc-1"
  subnet_ids                    = ["subnet-a", "subnet-b", "subnet-c"]
  ecs_cluster                   = { name = "classroom-prod-media-eu-central-1", arn = "arn:aws:ecs:eu-central-1:123456789012:cluster/classroom-prod-media-eu-central-1" }
  capacity_provider_association = "assoc"
  images = {
    sfu     = "123456789012.dkr.ecr.eu-central-1.amazonaws.com/classroom/sfu:bootstrap"
    capture = "123456789012.dkr.ecr.eu-central-1.amazonaws.com/classroom/capture:bootstrap"
  }
  instance_types        = ["c7gn.2xlarge", "c6gn.2xlarge"]
  architecture          = "arm64"
  ipv6                  = false
  workers               = 8
  rtc_port_base         = 40000
  pipe_port_range       = { min = 41000, max = 41999 }
  control_port          = 7443
  control_ingress_cidr  = "10.0.0.0/16"
  min_nodes             = 3
  max_nodes             = 24
  target_load_score     = 0.6
  max_load_score        = 0.9
  consumers_per_worker  = 500
  egress_capacity_mbps  = 5000
  drain_timeout_minutes = 240
  spot_allowed          = false
  secret_arns = {
    redis_state_url = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:redis-AbCdEf"
    control_tls     = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:sfu-tls-AbCdEf"
    control_ca      = "arn:aws:secretsmanager:eu-central-1:123456789012:secret:ca-AbCdEf"
  }
  secrets_kms_key_arn   = "arn:aws:kms:eu-central-1:123456789012:key/k"
  logs_kms_key_arn      = "arn:aws:kms:eu-central-1:123456789012:key/l"
  log_retention_days    = 90
  alarm_topic_arn       = "arn:aws:sns:eu-central-1:123456789012:t"
  recordings_bucket_arn = "arn:aws:s3:::classroom-prod-recordings"
}

run "unit" {
  command = plan

  assert {
    condition     = join(",", local.repository_arns) == "arn:aws:ecr:eu-central-1:123456789012:repository/classroom/sfu,arn:aws:ecr:eu-central-1:123456789012:repository/classroom/capture"
    error_message = "both image repositories are pullable"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.media["udp-ipv4"].from_port == 40000 && aws_vpc_security_group_ingress_rule.media["udp-ipv4"].to_port == 40007 && length(aws_vpc_security_group_ingress_rule.media) == 2
    error_message = "exactly the WebRtcServer ports, UDP and TCP, IPv4 only"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.control.cidr_ipv4 == "10.0.0.0/16"
    error_message = "control port only from the core VPC"
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.sfu.user_data), "net.ipv4.ip_local_reserved_ports = 40000-40007,41000-41999,45000-45999")
    error_message = "mediasoup ports reserved from the ephemeral range"
  }
  assert {
    condition     = strcontains(base64decode(aws_launch_template.sfu.user_data), "{\"media-pool\":\"sfu\"}")
    error_message = "ECS instance attribute"
  }
  assert {
    condition     = contains([for e in jsondecode(aws_ecs_task_definition.sfu.container_definitions)[0].environment : "${e.name}=${e.value}"], "MEDIA_PUBLIC_ADDRESS_SOURCE=imds")
    error_message = "SFU resolves its address from IMDS"
  }
  assert {
    condition     = contains([for s in jsondecode(aws_ecs_task_definition.sfu.container_definitions)[0].secrets : s.valueFrom], "arn:aws:secretsmanager:eu-central-1:123456789012:secret:sfu-tls-AbCdEf:key::")
    error_message = "control TLS key injected from the JSON secret"
  }
  assert {
    condition     = length([for e in jsondecode(aws_ecs_task_definition.sfu.container_definitions)[0].environment : e if startswith(e.name, "TURN")]) == 0
    error_message = "the SFU gets no TURN configuration at all"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.sfu.container_definitions)[1].essential == false
    error_message = "capture failure never stops lessons"
  }
  assert {
    condition     = aws_ecs_service.sfu["blue"].desired_count == 3 && aws_ecs_service.sfu["green"].desired_count == 0
    error_message = "colours"
  }
  assert {
    condition     = aws_autoscaling_group.sfu.max_size == 49
    error_message = "2 x max_nodes + 1"
  }
  assert {
    condition     = aws_appautoscaling_policy.sfu_load["blue"].target_tracking_scaling_policy_configuration[0].disable_scale_in
    error_message = "scale-out only"
  }
}