# infra/envs/staging/media-edge.eu-central-1.tfvars
#
# Media plane of STAGING in eu-central-1: production topology at reduced size. Every pool has two nodes in two
# different availability zones, so the paths that only exist with more than one node are exercised before
# production — cascading between SFU nodes, TURN backup node in another AZ, node loss and drain, blue/green TURN
# deploys, placement skipping draining nodes, and the load tests in ops/load/.
#
#   tofu -chdir=infra/media-edge init  -backend-config=../envs/staging/backend.hcl \
#                                       -backend-config="key=media-edge/eu-central-1.tfstate"
#   tofu -chdir=infra/media-edge apply -var-file=../envs/staging/media-edge.eu-central-1.tfvars

environment  = "staging"
region       = "eu-central-1"
region_short = "euc1"

availability_zone_ids = ["euc1-az1", "euc1-az2", "euc1-az3"]

vpc_cidr            = "10.64.0.0/16"
transit_gateway_asn = 64513

core_remote_state = {
  bucket         = "classroom-staging-terraform-state"
  key            = "core.tfstate"
  region         = "eu-central-1"
  dynamodb_table = "classroom-staging-terraform-locks"
}

sfu = {
  instance_types        = ["c7gn.xlarge", "c6gn.xlarge"]
  architecture          = "arm64"
  workers               = 4 # ports 40000-40003 udp+tcp
  rtc_port_base         = 40000
  pipe_port_range       = { min = 41000, max = 41999 }
  control_port          = 7443
  min_nodes             = 2 # spread over two AZs by the capacity provider
  max_nodes             = 4
  target_load_score     = 0.6
  max_load_score        = 0.9
  consumers_per_worker  = 500
  egress_capacity_mbps  = 2500
  drain_timeout_minutes = 240 # same as production so drain behaviour is tested realistically
  spot_allowed          = false
  ipv6                  = false
}

turn = {
  instance_types        = ["c7gn.large", "c6gn.large"]
  architecture          = "arm64"
  min_nodes             = 2 # two AZs: the backup TURN entry of every ICE configuration is in the other AZ
  max_nodes             = 4
  capacity_mbps         = 1500
  total_quota           = 2000
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
  sfu  = 5 # 4 + 1
  turn = 9 # 2 × 4 + 1
}

canary = {
  enabled  = true
  schedule = "rate(1 minute)"
}

log_retention_days = 30
alarm_topic_name   = "classroom-staging-alarms"

tags = {
  CostCenter = "engineering"
}