// classroom-app/infra/core/iam.tf
/**
 * IAM  (F4, F7, F8)  [EXT]
 *
 * One execution role for pulling images and reading secrets at task start, one
 * task role per service for what that service actually does at runtime, and one
 * role per Lambda. Nothing shares a role with something that needs different
 * permissions, because a shared role is how the API ends up able to complete an
 * ASG lifecycle action.
 *
 * Version 7 adds the media plane's operational roles:
 *
 *   node-lifecycle        attaches Elastic IPs, updates prefix lists and DNS,
 *                         writes drain flags and completes lifecycle actions
 *                         for both the SFU and TURN pools
 *   turn-secret-rotation  the three-phase rotation of the TURN shared secret
 *   acme-renewer          DNS-01 for *.<rtc_domain>, because ACM certificates
 *                         cannot be installed on EC2
 *   publish-ip-ranges     writes media-ip-ranges.json to the CDN so customer
 *                         IT can allowlist the platform
 *   turn-canary           mints a credential and proves a relayed path works
 *
 * The SFU and TURN instance roles live with their pools in
 * modules/sfu-node-pool and modules/turn-node-pool, next to the nodes they
 * belong to.
 */

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  ecs_assume_role = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })

  lambda_assume_role = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ---------------------------------------------------------------------------
# Execution role — used before the container starts
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-execution"
  assume_role_policy = local.ecs_assume_role
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

/**
 * Task definitions inject secrets with `valueFrom`, which the execution role
 * resolves. config/secrets.js fetches the rest with the task role at boot; both
 * paths need the same KMS key.
 */
resource "aws_iam_role_policy" "task_execution_secrets" {
  name = "secrets"
  role = aws_iam_role.task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = values(local.secret_arns)
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.secrets.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.ecr.arn]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Task roles
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task" {
  for_each = toset(["api", "realtime", "worker"])

  name               = "${local.name}-task-${each.key}"
  assume_role_policy = local.ecs_assume_role
  tags               = merge(local.tags, { Role = each.key })
}

/** Reading its own secrets at boot, and nothing else's. */
resource "aws_iam_role_policy" "task_secrets" {
  for_each = aws_iam_role.task

  name = "secrets"
  role = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = local.secret_arns_by_role[each.key]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.secrets.arn]
      },
    ]
  })
}

/** Logs, metrics and traces: the same three for every service. */
resource "aws_iam_role_policy" "task_observability" {
  for_each = aws_iam_role.task

  name = "observability"
  role = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.services.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = ["*"]
      },
    ]
  })
}

/**
 * Media: presigned uploads, quarantine promotion, signed delivery, transcoding
 * and captions. The api presigns and promotes; the worker runs MediaConvert and
 * Transcribe jobs. realtime touches none of it.
 */
resource "aws_iam_role_policy" "task_media" {
  for_each = { for role in ["api", "worker"] : role => aws_iam_role.task[role] }

  name = "media"
  role = each.value.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = [
            "s3:PutObject",
            "s3:GetObject",
            "s3:DeleteObject",
            "s3:AbortMultipartUpload",
            "s3:ListBucketMultipartUploads",
            "s3:ListMultipartUploadParts",
          ]
          Resource = [
            "${aws_s3_bucket.raw.arn}/*",
            "${aws_s3_bucket.quarantine.arn}/*",
            "${aws_s3_bucket.delivery.arn}/*",
            "${aws_s3_bucket.recordings.arn}/*",
          ]
        },
        {
          Effect = "Allow"
          Action = ["s3:ListBucket", "s3:GetBucketLocation"]
          Resource = [
            aws_s3_bucket.raw.arn,
            aws_s3_bucket.quarantine.arn,
            aws_s3_bucket.delivery.arn,
            aws_s3_bucket.recordings.arn,
          ]
        },
        {
          Effect   = "Allow"
          Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
          Resource = [aws_kms_key.media.arn]
        },
      ],
      each.key == "worker" ? [
        {
          Effect = "Allow"
          Action = [
            "mediaconvert:CreateJob",
            "mediaconvert:GetJob",
            "mediaconvert:ListJobs",
            "mediaconvert:DescribeEndpoints",
          ]
          Resource = ["*"]
        },
        {
          Effect   = "Allow"
          Action   = ["iam:PassRole"]
          Resource = [aws_iam_role.mediaconvert.arn]
          Condition = {
            StringEquals = { "iam:PassedToService" = "mediaconvert.amazonaws.com" }
          }
        },
        {
          Effect   = "Allow"
          Action   = ["transcribe:StartTranscriptionJob", "transcribe:GetTranscriptionJob"]
          Resource = ["*"]
        },
      ] : [],
    )
  })
}

/** Notifications: push through SNS platform applications, e-mail through SES. */
resource "aws_iam_role_policy" "task_notifications" {
  name = "notifications"
  role = aws_iam_role.task["worker"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sns:Publish",
          "sns:CreatePlatformEndpoint",
          "sns:DeleteEndpoint",
          "sns:GetEndpointAttributes",
          "sns:SetEndpointAttributes",
        ]
        Resource = [
          aws_sns_platform_application.apns.arn,
          aws_sns_platform_application.fcm.arn,
          "arn:${local.partition}:sns:${var.region}:${local.account_id}:endpoint/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = ["*"]
        Condition = {
          StringEquals = { "ses:FromAddress" = "no-reply@${var.domain}" }
        }
      },
    ]
  })
}

/**
 * [V7] The realtime service mints TURN credentials, so it needs the ring and
 * the pepper — already granted above — and nothing on the media plane itself.
 * It never calls EC2, never reads the ASG, never touches a node: it reaches
 * nodes over mTLS on the control port, and the network rule is the boundary.
 */
resource "aws_iam_role_policy" "realtime_registry" {
  name = "registry"
  role = aws_iam_role.task["realtime"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = ["*"]
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "Classroom" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# MediaConvert
# ---------------------------------------------------------------------------

resource "aws_iam_role" "mediaconvert" {
  name = "${local.name}-mediaconvert"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "mediaconvert.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "mediaconvert" {
  name = "transcode"
  role = aws_iam_role.mediaconvert.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.raw.arn}/*", "${aws_s3_bucket.delivery.arn}/*", "${aws_s3_bucket.recordings.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.media.arn]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# [V7] Lambda roles
# ---------------------------------------------------------------------------

resource "aws_iam_role" "lambda" {
  for_each = toset([
    "node-lifecycle",
    "turn-secret-rotation",
    "acme-renewer",
    "publish-ip-ranges",
    "turn-canary",
  ])

  name               = "${local.name}-fn-${each.key}"
  assume_role_policy = local.lambda_assume_role
  tags               = merge(local.tags, { Function = each.key })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  for_each = aws_iam_role.lambda

  role       = each.value.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# node-lifecycle and turn-secret-rotation run inside the VPC.
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  for_each = { for name in ["node-lifecycle", "turn-secret-rotation"] : name => aws_iam_role.lambda[name] }

  role       = each.value.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

/**
 * Launch: attach an Elastic IP from the pool, add the address to the published
 * prefix list, create the node's DNS record, complete the hook.
 * Terminate: set the drain flag, wait for the node to finish, complete the hook.
 */
resource "aws_iam_role_policy" "lambda_node_lifecycle" {
  name = "lifecycle"
  role = aws_iam_role.lambda["node-lifecycle"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeAddresses",
          "ec2:AssociateAddress",
          "ec2:DisassociateAddress",
          "ec2:DescribeManagedPrefixLists",
          "ec2:GetManagedPrefixListEntries",
          "ec2:ModifyManagedPrefixList",
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:CompleteLifecycleAction",
          "autoscaling:RecordLifecycleActionHeartbeat",
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
        ]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:GetChange"]
        Resource = ["arn:${local.partition}:route53:::hostedzone/${aws_route53_zone.rtc.zone_id}", "arn:${local.partition}:route53:::change/*"]
      },
    ]
  })
}

/**
 * Three phases: stage a new version (AWSPENDING), move AWSCURRENT so the API
 * starts signing with it, and retire the old one after the maximum credential
 * TTL. The function also reads the TURN registry to confirm that every node
 * accepts the staged secret before phase two.
 */
resource "aws_iam_role_policy" "lambda_turn_rotation" {
  name = "rotation"
  role = aws_iam_role.lambda["turn-secret-rotation"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = [aws_secretsmanager_secret.turn_shared_secret.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetRandomPassword"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.secrets.arn]
      },
    ]
  })
}

resource "aws_iam_role_policy" "lambda_acme_renewer" {
  name = "acme"
  role = aws_iam_role.lambda["acme-renewer"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:GetChange", "route53:ListResourceRecordSets"]
        Resource = ["arn:${local.partition}:route53:::hostedzone/${aws_route53_zone.rtc.zone_id}", "arn:${local.partition}:route53:::change/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:PutSecretValue", "secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [aws_secretsmanager_secret.turn_tls.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [aws_kms_key.secrets.arn]
      },
      # A renewal 30 days before expiry triggers a rolling instance refresh, so
      # every node picks the new certificate up without a manual step.
      {
        Effect   = "Allow"
        Action   = ["autoscaling:StartInstanceRefresh", "autoscaling:DescribeAutoScalingGroups"]
        Resource = ["*"]
      },
    ]
  })
}

/** media-ip-ranges.json: the file customer firewalls are configured from. */
resource "aws_iam_role_policy" "lambda_publish_ip_ranges" {
  name = "publish"
  role = aws_iam_role.lambda["publish-ip-ranges"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeAddresses", "ec2:GetManagedPrefixListEntries", "ec2:DescribeManagedPrefixLists"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.web.arn}/media-ip-ranges.json"]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = [aws_cloudfront_distribution.web.arn]
      },
    ]
  })
}

/** The canary mints a real credential and allocates on a real TURN node. */
resource "aws_iam_role_policy" "lambda_turn_canary" {
  name = "canary"
  role = aws_iam_role.lambda["turn-canary"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.turn_shared_secret.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.secrets.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = ["*"]
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "Classroom" }
        }
      },
    ]
  })
}

locals {
  task_role_arns = { for role, iam_role in aws_iam_role.task : role => iam_role.arn }
  lambda_role_arns = { for name, iam_role in aws_iam_role.lambda : name => iam_role.arn }
}