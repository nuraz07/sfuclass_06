// classroom-app/infra/core/ecr.tf
/**
 * Container registry  (F7, F8)  [EXT]
 *
 * Five images, one repository each: api (which also runs realtime), sfu,
 * capture, worker and turn. Built once per commit, scanned, signed, and
 * promoted by digest through staging into production — the same bytes
 * everywhere, which is what makes a rollback a task-definition revert.
 *
 * Version 7 adds the capture and turn repositories and replication into every
 * media region. A media region pulling an image across a region boundary on
 * every scale-out would add seconds to a cold start and a NAT bill to each one;
 * worse, it makes the control-plane region a hard dependency for bringing media
 * capacity online.
 */

data "aws_caller_identity" "current" {}

locals {
  ecr_repositories = {
    api     = "Express API and the realtime service (same image, SERVICE_ROLE decides)"
    sfu     = "mediasoup node: workers, WebRtcServers, control RPC"
    capture = "RTP capture sidecar in the SFU task"
    worker  = "BullMQ workers, ffmpeg, scheduled jobs"
    turn    = "coturn plus the agent sidecar"
  }

  # Images that only media regions run. The others are replicated too, because
  # a region that cannot pull the capture sidecar cannot record a lesson.
  ecr_replica_regions = distinct([
    for media_region in var.media_regions : media_region.region
    if media_region.enabled && media_region.region != var.region
  ])
}

resource "aws_ecr_repository" "this" {
  for_each = local.ecr_repositories

  name                 = "${var.project}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # a tag always means the same digest

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = merge(local.tags, { Name = "${var.project}/${each.key}", Purpose = each.value })
}

/**
 * Keep what a rollback might need and nothing else. Untagged layers are build
 * leftovers; thirty tagged images is roughly a month of releases.
 */
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "keep the last 30 release images"
        selection = {
          tagStatus     = "tagged"
          tagPatternList = ["*"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "expire untagged layers after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
    ]
  })
}

/**
 * Replication is account-wide, not per repository: one configuration covers
 * every repository whose name starts with the project prefix, including ones
 * added later.
 */
resource "aws_ecr_replication_configuration" "media_regions" {
  count = length(local.ecr_replica_regions) > 0 ? 1 : 0

  replication_configuration {
    rule {
      dynamic "destination" {
        for_each = toset(local.ecr_replica_regions)

        content {
          region      = destination.value
          registry_id = data.aws_caller_identity.current.account_id
        }
      }

      repository_filter {
        filter      = "${var.project}/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

/**
 * Pulls come from ECS task execution roles in this account and from the media
 * regions' instance roles, which are the same account. Nothing outside it may
 * pull, and nobody but the CI deploy role may push (github-oidc.tf).
 */
resource "aws_ecr_repository_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPullFromThisAccount"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
      },
      {
        Sid       = "AllowReplication"
        Effect    = "Allow"
        Principal = { Service = "ecr.amazonaws.com" }
        Action    = ["ecr:ReplicateImage"]
      },
    ]
  })
}

locals {
  ecr_repository_urls = { for name, repository in aws_ecr_repository.this : name => repository.repository_url }
}