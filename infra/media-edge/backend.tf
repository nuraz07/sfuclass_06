# infra/media-edge/backend.tf
#
# Separate state per media region, in the same encrypted state bucket as the core stack:
#
#   s3://classroom-<env>-terraform-state/media-edge/<region>.tfstate
#
# Partial configuration on purpose: bucket, region, lock table and KMS key come from
# infra/envs/<env>/backend.hcl, the key is set per region by .github/workflows/terraform.yml:
#
#   tofu -chdir=infra/media-edge init \
#     -backend-config=../envs/<env>/backend.hcl \
#     -backend-config="key=media-edge/<region>.tfstate"
#
# A broken media region can therefore be planned, applied or rolled back without touching the core stack or any
# other region, and state locks never block another region's pipeline.
#
# Owner: F7 Production and Operations.

terraform {
  backend "s3" {}
}