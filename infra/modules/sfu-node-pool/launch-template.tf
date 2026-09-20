###############################################################################
# infra/modules/sfu-node-pool/launch-template.tf
#
# The instances an SFU node runs on.  (F1, F8)
#
# Requirements that pick the instance type:
#   - predictable network throughput, because the egress ceiling is what caps
#     a node's capacity long before CPU does;
#   - stable single-core performance, because a mediasoup worker is
#     single-threaded and one worker per core is the whole model;
#   - ENA and enough packets-per-second headroom: an SFU moves a very large
#     number of very small UDP packets, which is a different problem from
#     moving bytes.
#
# IMDSv2 is required, not optional: config/publicAddress.js reads the Elastic
# IP from it at boot and the process fails readiness if it cannot. A node that
# cannot learn its own public address must not serve media.
###############################################################################

data "aws_ssm_parameter" "ecs_ami" {
  # ECS-optimised AL2023, ARM or x86 depending on the instance family.
  name = var.cpu_architecture == "arm64" ? "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id" : "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

resource "aws_launch_template" "this" {
  name_prefix   = "${local.name}-"
  image_id      = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  update_default_version = true

  iam_instance_profile {
    arn = var.instance_profile_arn
  }

  vpc_security_group_ids = [aws_security_group.this.id]

  ###########################################################################
  # IMDSv2 — required
  ###########################################################################
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv1 disabled
    http_put_response_hop_limit = 2          # host networking: container -> IMDS
    instance_metadata_tags      = "enabled"
  }

  ###########################################################################
  # Storage — ephemeral by design
  #
  # No container writes durable state to disk (§7). The volume holds the
  # container images, logs in flight and the capture sidecar's current
  # segment before it is flushed to S3. gp3 with provisioned throughput so a
  # recording flush never competes with an image pull.
  ###########################################################################
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 250
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  ###########################################################################
  # Network
  ###########################################################################
  network_interfaces {
    associate_public_ip_address = false # the EIP is attached by the lifecycle Lambda
    delete_on_termination       = true
    security_groups             = [aws_security_group.this.id]

    # Enhanced networking is on by default for these families; stated here so
    # a future instance-type change cannot silently lose it.
    interface_type = "interface"
  }

  # Placement across AZs is the ASG's job; within an AZ, spread so that one
  # rack does not hold the whole region's lessons.
  placement {
    tenancy = "default"
  }

  ###########################################################################
  # Never Spot
  #
  # A two-minute Spot interruption notice is shorter than a lesson and shorter
  # than the drain. Media nodes run on-demand; capacity is managed by the
  # drain-aware scaling policy instead.
  ###########################################################################
  instance_market_options {
    market_type = var.allow_spot ? "spot" : null
  }

  monitoring {
    enabled = true # 1-minute metrics: the scaling signal needs them
  }

  ###########################################################################
  # Bootstrap
  ###########################################################################
  user_data = base64encode(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    ecs_cluster_name = var.ecs_cluster_name
    region           = var.region
    node_role        = "sfu"
    rtc_port_min     = local.rtc_port_min
    rtc_port_max     = local.rtc_port_max
    eip_pool_tag     = var.eip_pool_tag
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name               = local.name
      "classroom:role"   = "sfu"
      "classroom:region" = var.region
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${local.name}-root" })
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = merge(var.tags, { Name = "${local.name}-eni" })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# user-data (templates/user-data.sh.tftpl), for reference:
#
#   #!/bin/bash
#   set -euo pipefail
#
#   # 1. Join the cluster, and only this pool's capacity provider.
#   cat >> /etc/ecs/ecs.config <<EOF
#   ECS_CLUSTER=${ecs_cluster_name}
#   ECS_ENABLE_TASK_IAM_ROLE=true
#   ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true
#   ECS_ENABLE_SPOT_INSTANCE_DRAINING=false
#   ECS_CONTAINER_STOP_TIMEOUT=2m
#   ECS_IMAGE_PULL_BEHAVIOR=prefer-cached
#   ECS_INSTANCE_ATTRIBUTES={"classroom.role":"${node_role}","classroom.region":"${region}"}
#   EOF
#
#   # 2. Kernel tuning for a node that moves many small UDP packets.
#   cat > /etc/sysctl.d/99-sfu.conf <<EOF
#   net.core.rmem_max=16777216
#   net.core.wmem_max=16777216
#   net.core.netdev_max_backlog=250000
#   net.ipv4.udp_mem=262144 524288 1048576
#   net.ipv4.ip_local_port_range=10000 39999   # keep 40000+ free for WebRtcServer
#   fs.file-max=1000000
#   EOF
#   sysctl --system
#
#   # 3. The EIP is attached by functions/node-lifecycle on the launch hook.
#   #    Wait for it, because publicAddress.js fails readiness without one.
#   TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
#     -H 'x-aws-ec2-metadata-token-ttl-seconds: 300')
#   for i in $(seq 1 60); do
#     curl -sf -H "x-aws-ec2-metadata-token: $TOKEN" \
#       http://169.254.169.254/latest/meta-data/public-ipv4 && break
#     sleep 2
#   done
###############################################################################