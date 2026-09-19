# infra/media-edge/providers.tf
#
# One media region per state: the region comes from the environment's tfvars file
# (infra/envs/<env>/media-edge.<region>.tfvars), everything the region needs from the control plane comes from the
# core stack's outputs (remote state), and the few objects that must live in the control-plane region — the hub side
# of the Transit Gateway peering and the published address list — are managed through the "core" provider alias.
#
# Tested with OpenTofu 1.9 and AWS provider 5.94 and 6.14.
#
# Owner: F8 Real-Time Connectivity + F7 Production and Operations.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
}

locals {
  default_tags = merge(var.tags, {
    Project     = "classroom-platform"
    Environment = var.environment
    Stack       = "media-edge"
    MediaRegion = var.region
    ManagedBy   = "terraform"
  })
}

# The media region itself.
provider "aws" {
  region = var.region

  default_tags {
    tags = local.default_tags
  }
}

# The control-plane region (hub Transit Gateway, published address parameters).
provider "aws" {
  alias  = "core"
  region = var.core_remote_state.region

  default_tags {
    tags = local.default_tags
  }
}

# Outputs of infra/core (transit.tf, route53.tf, secrets.tf, ecr.tf …) for the same environment.
data "terraform_remote_state" "core" {
  backend = "s3"

  config = {
    bucket = var.core_remote_state.bucket
    key    = var.core_remote_state.key
    region = var.core_remote_state.region
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}