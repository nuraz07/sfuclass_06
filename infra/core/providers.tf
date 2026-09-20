###############################################################################
# infra/core/providers.tf
#
# Control-plane stack: providers and version pins.  (F7)
#
# v6 -> v7 corrections:
#   - the file was named "porviders.tf". A typo in a filename is harmless until
#     someone greps for it during an incident; renamed.
#   - a us-east-1 alias is now required. CloudFront certificates and
#     CloudFront-scoped WAF web ACLs can only exist in us-east-1, whatever the
#     primary region is (ours is eu-central-1).
#
# State: S3 + DynamoDB lock, key core.tfstate (backend.tf). The media plane
# keeps its own state per region (infra/media-edge), so a broken apply in one
# media region cannot touch the control plane.
###############################################################################

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60.0, < 7.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

###############################################################################
# Primary region — everything except CloudFront-scoped resources
###############################################################################

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }

  # Guard against a stale or wrong credential profile pointing an apply at
  # another account. The value comes from the environment's tfvars.
  allowed_account_ids = [var.account_id]
}

###############################################################################
# us-east-1 — CloudFront certificates and CloudFront WAF only
###############################################################################

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.tags
  }

  allowed_account_ids = [var.account_id]
}

###############################################################################
# Identity of the account this stack is applied to
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

###############################################################################
# Remote state consumed by the media-edge stacks
#
# media-edge/providers.tf reads this stack's outputs (registry endpoint,
# Transit Gateway id, secret ARNs, prefix lists). The dependency is one-way:
# core never reads media-edge state, so a media region can be added, rebuilt
# or destroyed without planning the control plane.
###############################################################################