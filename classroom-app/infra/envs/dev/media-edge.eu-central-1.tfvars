# infra/envs/dev/media-edge.eu-central-1.tfvars
#
# Media plane of the DEV environment in eu-central-1: the smallest topology that still exercises every path —
# one SFU node, one TURN node, Elastic IPs, Transit Gateway peering to the dev core, registry heartbeats, drain.
#
#   tofu -chdir=infra/media-edge init  -backend-config=../envs/dev/backend.hcl \
#                                       -backend-config="key=media-edge/eu-central-1.tfstate"
#   tofu -chdir=infra/media-edge apply -var-file=../envs/dev/media-edge.eu-central-1.tfvars
# (.github/workflows/terraform.yml runs exactly this per environment and region.)
#
# Cost over resilience: single node per pool, Spot allowed, short log retention. Not for load or failover tests —
# use staging for those.

environment  = "dev"
region       = "eu-central-1"
region_short = "euc1" # node names: sfu-euc1-<instance>, turn-euc1-NN

# AZ IDs (not names) so placement is identical across AWS accounts. Two subnets, one node.
availability_zone_ids = ["euc1-az1", "euc1-az2"]

# Inside the dev core's media_edge_supernet (10.64.0.0/10); one /16 per media region.
vpc_cidr            = "10.64.0.0/16"
transit_gateway_asn = 64513 # hub uses 64512

core_remote_state = {
  bucket         = "classroom-dev-terraform-state"
  key            = "core.tfstate"
  region         = "eu-central-1"
  dynamodb_table = "classroom-dev-terraform-locks"
}

sfu = {
  instance_types        = ["c7gn.large", "c6gn.large"] # first available type wins (mixed instances policy)
  architecture          = "arm64"
  workers               = 2 # one mediasoup worker per vCPU → WebRtcServer ports 40000-40001 udp+tcp
  rtc_port_base         = 40000
  pipe_port_range       = { min = 41000, max = 41999 }
  control_port          = 7443
  min_nodes             = 1
  max_nodes             = 2
  target_load_score     = 0.6 # autoscaling target (sfu.load_score)
  max_load_score        = 0.9 # node reports unhealthy above this
  consumers_per_worker  = 500
  egress_capacity_mbps  = 1000 # planning value, well below the instance baseline
  drain_timeout_minutes = 30   # dev lessons are short; no reason to hold instances for hours
  spot_allowed          = true
  ipv6                  = false
}

turn = {
  instance_types        = ["c7gn.medium", "c6gn.medium"]
  architecture          = "arm64"
  min_nodes             = 1
  max_nodes             = 1
  capacity_mbps         = 500
  total_quota           = 500
  user_quota            = 12
  max_bps               = 0 # bytes/s per allocation, 0 = unlimited
  bps_capacity          = 0 # bytes/s per node, 0 = unlimited
  relay_port_range      = { min = 49152, max = 65535 }
  target_load_ratio     = 0.6
  drain_timeout_minutes = 30
  spot_allowed          = true
}

# Pre-allocated Elastic IPs. SFU: max nodes + 1 for instance refresh. TURN: 2 × max nodes + 1 because
# deploy-turn.yml runs blue/green (both colours hold addresses while the old one drains).
# Needs the regional Elastic IP quota (default 5 per region) raised to at least sfu + turn + NAT gateways
# before the first apply (Service Quotas: "EC2-VPC Elastic IPs").
eip_pool = {
  sfu  = 3
  turn = 3
}

canary = {
  enabled  = true
  schedule = "rate(5 minutes)"
}

log_retention_days = 14
alarm_topic_name   = "classroom-dev-alarms"

tags = {
  CostCenter = "engineering"
}