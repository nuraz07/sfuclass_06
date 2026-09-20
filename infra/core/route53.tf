###############################################################################
# infra/core/route53.tf
#
# DNS for the control plane, plus delegation of the rtc zone.  (F7, F8)
#
# v6 -> v7 corrections:
#   - the public sfu-* records are gone. Public SFU hostnames needed
#     certificates they never used, widened the attack surface and created a
#     second way to reach a node next to the join acknowledgement. Clients
#     receive SFU addresses as ICE candidates (raw IPs), never as DNS.
#   - a separate rtc zone is delegated from the primary zone. TURN node
#     records (turn-<region>-NN) are written by the node-lifecycle Lambda in
#     each media region, at node launch and at drain. Delegating the zone means
#     that Lambda gets write access to rtc.example.com only, not to the zone
#     that holds app, api and ws.
#
# Names:
#   app     SPA (CloudFront)
#   api     REST API (ALB)
#   ws      Socket.IO / realtime service (ALB, separate name so it can move)
#   cdn     hashed static assets (CloudFront)
#   media   signed HLS and file delivery (CloudFront)
#   rtc.*   delegated zone: TURN nodes, managed per region
###############################################################################

data "aws_route53_zone" "primary" {
  name         = var.domain_name
  private_zone = false
}

###############################################################################
# Application records
###############################################################################

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "app.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.spa.domain_name
    zone_id                = aws_cloudfront_distribution.spa.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "app_v6" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "app.${var.domain_name}"
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.spa.domain_name
    zone_id                = aws_cloudfront_distribution.spa.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "api_v6" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "api.${var.domain_name}"
  type    = "AAAA"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# Separate name for WebSockets even though it resolves to the same ALB today:
# the realtime service has its own scaling profile and may need its own load
# balancer later. Clients already point at ws.<domain>, so that move is a DNS
# change instead of a client release.
resource "aws_route53_record" "ws" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "ws.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "cdn" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "cdn.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.spa.domain_name
    zone_id                = aws_cloudfront_distribution.spa.hosted_zone_id
    evaluate_target_health = false
  }
}

# Signed HLS, recordings and chat attachments. A separate distribution and a
# separate origin from the SPA: attachments must never share an origin with
# application code (security baseline, §13).
resource "aws_route53_record" "media" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = "media.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.delivery.domain_name
    zone_id                = aws_cloudfront_distribution.delivery.hosted_zone_id
    evaluate_target_health = false
  }
}

###############################################################################
# rtc zone — delegated
#
# Records inside it are NOT managed by Terraform: turn-<region>-NN is created
# when a TURN node attaches its Elastic IP and removed when it drains, both by
# functions/node-lifecycle. Terraform owns the zone and the delegation; the
# Lambda owns the contents. That split is why the zone exists.
###############################################################################

resource "aws_route53_zone" "rtc" {
  name    = var.rtc_domain # e.g. rtc.example.com
  comment = "TURN and media edge records; contents managed by node-lifecycle Lambda"

  tags = merge(local.tags, { Name = "${local.name_prefix}-rtc" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route53_record" "rtc_delegation" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.rtc_domain
  type    = "NS"
  ttl     = 172800
  records = aws_route53_zone.rtc.name_servers
}

###############################################################################
# Health checks
#
# Route 53 health checks exist for the status page and for alarm context, not
# for failover: placement decides where a room goes, and it uses the registry
# heartbeats, which are 15 s fresh. DNS is far too slow to steer media.
###############################################################################

resource "aws_route53_health_check" "api" {
  fqdn              = "api.${var.domain_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 30
  measure_latency   = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-api-health" })
}

###############################################################################
# DNSSEC and hygiene
###############################################################################

resource "aws_route53_record" "caa" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.domain_name
  type    = "CAA"
  ttl     = 3600

  # ACM for ALB and CloudFront; Let's Encrypt via ACME DNS-01 for the TURN
  # nodes' TLS on 443, which ACM cannot issue for EC2.
  records = [
    "0 issue \"amazon.com\"",
    "0 issue \"letsencrypt.org\"",
    "0 iodef \"mailto:security@${var.domain_name}\"",
  ]
}