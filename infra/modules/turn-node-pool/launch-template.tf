# infra/modules/turn-node-pool/launch-template.tf
#
# How a TURN instance boots:
#
#   AMI              latest ECS-optimised Amazon Linux 2023 for the architecture (SSM public parameter); a new AMI
#                    takes effect with the next instance refresh / blue-green switch
#   network          public media subnet, auto-assigned public IPv4 at launch so the ECS agent can register at once;
#                    the node-lifecycle Lambda then attaches the node's Elastic IP from the pool (launch hook)
#   IMDS             v2 only (http_tokens = required), hop limit 1 (host networking), instance tags readable — the
#                    bootstrap reads TurnNodeName / TurnHostname / TurnPublicIp from there (render-config.sh)
#   host tuning      ephemeral ports 32768-49151, so nothing else binds in the relay range 49152-65535 (the agent
#                    counts relay sockets there as a fallback); larger UDP buffers; high file-descriptor limits
#   ECS agent        cluster membership, attribute media-pool=turn, task IAM roles with host networking,
#                    120 s stop timeout
#   instance role    ECS container instance + SSM (deploy-turn.yml drains nodes through SSM Run Command)
#
# Owner: F8 Real-Time Connectivity.

data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/${var.architecture == "arm64" ? "arm64/" : ""}recommended/image_id"
}

# ------------------------------------------------------------------ instance role

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "instance_ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# ------------------------------------------------------------------ launch template

locals {
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail

    # ECS agent
    cat >> /etc/ecs/ecs.config <<'CFG'
    ECS_CLUSTER=${var.ecs_cluster.name}
    ECS_ENABLE_TASK_IAM_ROLE=true
    ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true
    ECS_CONTAINER_STOP_TIMEOUT=120s
    ECS_ENABLE_CONTAINER_METADATA=true
    ECS_INSTANCE_ATTRIBUTES={"media-pool":"turn"}
    ECS_WARM_POOLS_CHECK=false
    CFG

    # Host tuning for a relay (host networking: these apply to coturn directly)
    cat > /etc/sysctl.d/90-turn.conf <<'SYS'
    net.ipv4.ip_local_port_range = 32768 49151
    net.core.rmem_max = 16777216
    net.core.wmem_max = 16777216
    net.core.rmem_default = 1048576
    net.core.wmem_default = 1048576
    net.core.netdev_max_backlog = 250000
    net.ipv4.udp_mem = 262144 524288 1048576
    fs.file-max = 2097152
    SYS
    sysctl --system >/dev/null
  EOT
}

resource "aws_launch_template" "turn" {
  name_prefix            = "${local.name}-"
  description            = "TURN nodes ${var.region} (coturn + agent, ECS on EC2, host networking)"
  image_id               = data.aws_ssm_parameter.ecs_ami.value
  update_default_version = true
  user_data              = base64encode(local.user_data)

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  network_interfaces {
    device_index                = 0
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.turn.id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name      = local.name
      MediaPool = "turn"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name      = local.name
      MediaPool = "turn"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}