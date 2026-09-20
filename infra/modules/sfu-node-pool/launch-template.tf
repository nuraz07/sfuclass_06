# infra/modules/sfu-node-pool/launch-template.tf
#
# How an SFU instance boots:
#
#   AMI              latest ECS-optimised Amazon Linux 2023 for the architecture (SSM public parameter)
#   network          public media subnet, auto-assigned public IPv4 at launch so the ECS agent registers at once;
#                    the node-lifecycle Lambda then attaches the node's Elastic IP from the pool and tags the instance
#                    SfuSlot / SfuPublicIp — server/src/config/publicAddress.js waits for that tag before announcing
#   IMDS             v2 only, hop limit 1 (host networking), instance tags readable
#   host tuning      the mediasoup ports are reserved from the kernel's ephemeral range, so no outgoing connection can
#                    take 40000+i, the pipe range or the loopback capture range before mediasoup binds them;
#                    larger UDP buffers for media
#   ECS agent        cluster membership, attribute media-pool=sfu, task IAM roles with host networking, 120 s stop
#   instance role    ECS container instance + SSM (deploy-sfu.yml drains nodes through SSM Run Command)
#
# Owner: F1 Live Classrooms + F8 Real-Time Connectivity.

data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/${var.architecture == "arm64" ? "arm64/" : ""}recommended/image_id"
}

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

locals {
  reserved_ports = join(",", [
    "${var.rtc_port_base}-${local.rtc_port_max}",
    "${var.pipe_port_range.min}-${var.pipe_port_range.max}",
    "${var.capture_rtp_port_range.min}-${var.capture_rtp_port_range.max}",
  ])

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail

    cat >> /etc/ecs/ecs.config <<'CFG'
    ECS_CLUSTER=${var.ecs_cluster.name}
    ECS_ENABLE_TASK_IAM_ROLE=true
    ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true
    ECS_CONTAINER_STOP_TIMEOUT=120s
    ECS_ENABLE_CONTAINER_METADATA=true
    ECS_INSTANCE_ATTRIBUTES={"media-pool":"sfu"}
    CFG

    cat > /etc/sysctl.d/90-sfu.conf <<'SYS'
    net.ipv4.ip_local_reserved_ports = ${local.reserved_ports}
    net.core.rmem_max = 26214400
    net.core.wmem_max = 26214400
    net.core.rmem_default = 1048576
    net.core.wmem_default = 1048576
    net.core.netdev_max_backlog = 250000
    net.ipv4.udp_mem = 262144 524288 1048576
    fs.file-max = 2097152
    SYS
    sysctl --system >/dev/null
  EOT
}

resource "aws_launch_template" "sfu" {
  name_prefix            = "${local.name}-"
  description            = "SFU nodes ${var.region} (mediasoup + capture, ECS on EC2, host networking)"
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
    http_protocol_ipv6          = var.ipv6 ? "enabled" : "disabled"
  }

  network_interfaces {
    device_index                = 0
    associate_public_ip_address = true
    delete_on_termination       = true
    security_groups             = [aws_security_group.sfu.id]
    ipv6_address_count          = var.ipv6 ? 1 : 0
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
      MediaPool = "sfu"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name      = local.name
      MediaPool = "sfu"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}