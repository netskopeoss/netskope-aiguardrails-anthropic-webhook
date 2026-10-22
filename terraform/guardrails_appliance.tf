# Security groups, internal ALB, target group, listener, private DNS, and the
# VPE appliance Launch Template + Auto Scaling Group.
#
# The appliance boots with no UserData and no instance profile. After apply you
# activate it by hand (enroll, attach service templates, dataplane
# cert). See the deployment guide.

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.guardrails_name}-alb"
  description = "Internal ALB for AI Guardrails on Demand"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from the VPC and any additional client CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.alb_client_cidrs
  }

  egress {
    description = "HTTP to the appliance API"
    from_port   = var.guardrails_api_port
    to_port     = var.guardrails_api_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.guardrails_name}-alb-sg" }
}

resource "aws_security_group" "appliance" {
  name        = "${var.guardrails_name}-appliance"
  description = "AI Guardrails on Demand (VPE) appliance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API port from the ALB only"
    from_port       = var.guardrails_api_port
    to_port         = var.guardrails_api_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH for VPE CLI activation (VPC and additional client CIDR)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.alb_client_cidrs
  }

  egress {
    description = "All outbound: Netskope management plane, NTP, updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.guardrails_name}-appliance-sg" }
}

# ---------------------------------------------------------------------------
# Private hosted zone
# ---------------------------------------------------------------------------

resource "aws_route53_zone" "private" {
  name    = var.hosted_zone_name
  comment = "Private zone for ${var.guardrails_name} AI Guardrails ALB"

  vpc {
    vpc_id = aws_vpc.main.id
  }
}

resource "aws_route53_record" "guardrails" {
  zone_id = aws_route53_zone.private.zone_id
  name    = var.guardrails_domain_name
  type    = "A"

  alias {
    name                   = aws_lb.guardrails.dns_name
    zone_id                = aws_lb.guardrails.zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# Internal ALB: HTTPS 443 with the self-signed cert, forwarding HTTP to the appliance
# ---------------------------------------------------------------------------

resource "aws_lb" "guardrails" {
  name               = "${var.guardrails_name}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.private[*].id

  tags = { Name = "${var.guardrails_name}-alb" }
}

resource "aws_lb_target_group" "guardrails" {
  name        = "${var.guardrails_name}-tg"
  protocol    = "HTTP"
  port        = var.guardrails_api_port
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol            = "HTTP"
    port                = tostring(var.guardrails_api_port)
    path                = var.guardrails_health_check_path
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200-499"
  }

  tags = { Name = "${var.guardrails_name}-tg" }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.guardrails.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.alb.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.guardrails.arn
  }
}

# ---------------------------------------------------------------------------
# VPE appliance: Launch Template + Auto Scaling Group
# ---------------------------------------------------------------------------

resource "aws_launch_template" "guardrails" {
  name          = "${var.guardrails_name}-lt"
  image_id      = var.guardrails_ami_id
  instance_type = var.guardrails_instance_type
  key_name      = var.guardrails_key_name

  vpc_security_group_ids = [aws_security_group.appliance.id]

  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      encrypted   = true
      volume_size = var.guardrails_root_volume_gb
      volume_type = "gp3"
    }
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.guardrails_name}-appliance" }
  }
}

resource "aws_autoscaling_group" "guardrails" {
  name                = "${var.guardrails_name}-asg"
  min_size            = var.guardrails_min_capacity
  max_size            = var.guardrails_max_capacity
  desired_capacity    = var.guardrails_desired_capacity
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.guardrails.arn]

  # EC2 health check, not ELB: an appliance that is not yet activated fails the
  # API health check and must not be replaced in a loop.
  health_check_type         = "EC2"
  health_check_grace_period = 900

  launch_template {
    id      = aws_launch_template.guardrails.id
    version = aws_launch_template.guardrails.latest_version
  }

  tag {
    key                 = "Name"
    value               = "${var.guardrails_name}-appliance"
    propagate_at_launch = true
  }

  depends_on = [aws_route.private_nat]
}
