// classroom-app/infra/core/alb.tf
/**
 * Application load balancer  (F1, F6, F7)  [EXT]
 *
 * Terminates TLS for HTTP and for WebSockets. It carries signalling, chat,
 * presence and Yjs — and no media: WebRTC goes directly from the client to an
 * SFU node's Elastic IP, or through TURN. There is no listener here for
 * anything on the media path (Appendix A #1).
 *
 * Version 7 adds the realtime target group. The realtime service was described
 * as separate in version 6 but defined in ecs-api.tf, so ownership and scaling
 * contradicted each other (Appendix A #8). Now it has its own target group, its
 * own health check and its own scaling.
 *
 * The idle timeout is the detail that decides whether quiet classrooms stay
 * connected. The socket heartbeat is SOCKET_PING_INTERVAL_MS plus
 * SOCKET_PING_TIMEOUT_MS — 45 s by default — and the ALB must stay well above
 * it, or it will close connections that are healthy and every idle lesson
 * reconnects for nothing. `var.alb_idle_timeout_sec` enforces a floor of 120 s
 * and defaults to 300 s.
 *
 * Stickiness on the realtime group is an optimisation, not a requirement: the
 * sharded Redis Pub/Sub adapter makes any task able to serve any room, so a
 * lost sticky cookie costs a reconnect, not a session.
 */

resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  idle_timeout               = var.alb_idle_timeout_sec
  enable_http2               = true
  enable_deletion_protection = var.environment == "prod"
  drop_invalid_header_fields = true
  # X-Forwarded-For is what TRUST_PROXY and the IP rate limit depend on.
  xff_header_processing_mode = "append"

  access_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = "alb"
    enabled = true
  }

  tags = merge(local.tags, { Name = "${local.name}-alb" })
}

# ---------------------------------------------------------------------------
# Target groups
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "api" {
  name        = "${local.name}-api"
  port        = local.api_port
  protocol    = "HTTP"
  target_type = "ip" # awsvpc networking on Fargate
  vpc_id      = aws_vpc.main.id

  # Long enough for in-flight requests to finish, short enough that a deploy
  # does not crawl. gracefulShutdown.js stops answering /readyz first.
  deregistration_delay = 30

  health_check {
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.tags, { Name = "${local.name}-api" })

  lifecycle {
    create_before_destroy = true
  }
}

/**
 * [V7] Long-lived sockets. Draining takes longer than for the API, because a
 * client that is dropped mid-lesson has to rebuild its signalling state; the
 * deregistration delay gives socketClient.ts time to move to another task on
 * its own terms.
 */
resource "aws_lb_target_group" "realtime" {
  name        = "${local.name}-realtime"
  port        = local.realtime_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  deregistration_delay = 120

  health_check {
    path                = "/readyz"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = 3600
  }

  tags = merge(local.tags, { Name = "${local.name}-realtime" })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Listeners
# ---------------------------------------------------------------------------

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.regional.certificate_arn

  # Anything that matches no rule is not a request we want to reach a task.
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "application/json"
      message_body = jsonencode({ error = { code = "not_found" } })
      status_code  = "404"
    }
  }
}

# ---------------------------------------------------------------------------
# Rules — most specific first
# ---------------------------------------------------------------------------

/**
 * ws.<domain> is the client-facing name (PUBLIC_WS_URL). The /socket.io path
 * rule below is the fallback for a browser that reaches the API host with an
 * upgrade request, which happens behind proxies that rewrite Host headers.
 */
resource "aws_lb_listener_rule" "realtime_host" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.realtime.arn
  }

  condition {
    host_header {
      values = ["ws.${var.domain}"]
    }
  }
}

resource "aws_lb_listener_rule" "realtime_socket_path" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.realtime.arn
  }

  condition {
    path_pattern {
      values = ["/socket.io/*", "/collab/*"]
    }
  }
}

resource "aws_lb_listener_rule" "api_host" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    host_header {
      values = ["api.${var.domain}"]
    }
  }
}

# ---------------------------------------------------------------------------
# Outputs consumed by ecs-api.tf and ecs-realtime.tf
# ---------------------------------------------------------------------------

locals {
  alb_target_groups = {
    api      = aws_lb_target_group.api.arn
    realtime = aws_lb_target_group.realtime.arn
  }

  # The services depend on the listener, not just the target group: registering
  # targets before a listener exists leaves them unreachable but "healthy".
  alb_listeners = [aws_lb_listener.https.arn, aws_lb_listener.http.arn]
}