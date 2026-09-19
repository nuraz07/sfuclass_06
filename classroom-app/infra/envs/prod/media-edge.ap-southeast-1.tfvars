# infra/envs/prod/media-edge.ap-southeast-1.tfvars
#
# Media plane of PRODUCTION in ap-southeast-1 — third media region, Asia-Pacific.
# Smallest production pools; grow from the placement and relay metrics of this region
# (Classroom/Turn LoadRatio, sfu.load_score) rather than from global totals.
#
#   tofu -chdir=infra/media-edge init  -backend-config=../envs/prod/backend.hcl \
#                                       -backend-config="key=media-edge/ap-southeast-1.tfstate"
#   tofu -chdir=infra/media-edge apply -var-file=../envs/prod/media-edge.ap-southeast-1.tfvars
# (.github/workflows/terraform.yml: plan on pull requests, apply after approval, one region at a time.)
#
# Sizing rules used below:
#   SFU   c7gn.2xlarge (8 vCPU) → 8 mediasoup workers → WebRtcServer ports 40000-40007 udp+tcp.
#         One node per AZ minimum; autoscaling on sfu.load_score (target 0.6); new rooms only below 0.75.
#   TURN  bandwidth-bound: capacity_mbps is a planning value below the instance's sustained network baseline and is
#         calibrated with ops/load/turn-load.md before raising max_nodes. One node per AZ minimum, so the backup
#         entry of every ICE configuration sits in another AZ.
#   EIPs  sfu = max_nodes + 1 (instance refresh) · turn = 2 × max_nodes + 1 (blue/green deploy-turn.yml).
#         These addresses are published in media-ip-ranges.json for customer firewall allowlists — grow the pool
#         ahead of need and announce new ranges (ops/runbooks/customer-firewall.md); never shrink it silently.

environment  = "prod"
region       = "ap-southeast-1"
region_short = "apse1"

# AZ IDs, not names: the same physical zones in every account. Instance types are checked per AZ by the
# mixed-instances policy; the second type is the fallback where the first is not offered or out of capacity.
availability_zone_ids = ["apse1-az1", "apse1-az2", "apse1-az3"]

vpc_cidr            = "10.66.0.0/16" # inside the prod media_edge_supernet 10.64.0.0/10, unique per region
transit_gateway_asn = 64515          # hub 64512 · eu-central-1 64513 · us-east-1 64514 · ap-southeast-1 64515

core_remote_state = {
  bucket         = "classroom-prod-terraform-state"
  key            = "core.tfstate"
  region         = "eu-central-1"
  dynamodb_table = "classroom-prod-terraform-locks"
}

sfu = {
  instance_types        = ["c7gn.2xlarge", "c6gn.2xlarge"]
  architecture          = "arm64"
  workers               = 8
  rtc_port_base         = 40000
  pipe_port_range       = { min = 41000, max = 41999 }
  control_port          = 7443
  min_nodes             = 3
  max_nodes             = 12
  target_load_score     = 0.6
  max_load_score        = 0.9
  consumers_per_worker  = 500
  egress_capacity_mbps  = 5000
  drain_timeout_minutes = 240 # longest lesson plus margin
  spot_allowed          = false
  ipv6                  = false
}

turn = {
  instance_types        = ["c7gn.xlarge", "c6gn.xlarge"]
  architecture          = "arm64"
  min_nodes             = 3
  max_nodes             = 6
  capacity_mbps         = 4000
  total_quota           = 4000
  user_quota            = 12
  max_bps               = 0
  bps_capacity          = 0
  relay_port_range      = { min = 49152, max = 65535 }
  target_load_ratio     = 0.6
  drain_timeout_minutes = 240
  spot_allowed          = false
}

# Needs the regional Elastic IP quota (default 5 per region) raised to at least sfu + turn + NAT gateways
# before the first apply (Service Quotas: "EC2-VPC Elastic IPs").
eip_pool = {
  sfu  = 13
  turn = 13
  # public_ipv4_pool = "ipv4pool-ec2-..." # set when moving to BYOIP address ranges
}

canary = {
  enabled  = true
  schedule = "rate(1 minute)"
}

log_retention_days = 90
alarm_topic_name   = "classroom-prod-alarms"

tags = {
  CostCenter = "media-plane"
}