# ECS module: Fargate cluster + service running behind an internet-facing
# ALB. Tasks run in PRIVATE subnets with no public IP — the ALB in the
# public subnets is the only ingress path.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  image       = "${var.ecr_repository_url}:${var.image_tag}"
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${local.name_prefix}-cluster"
  }
}

# Application log group — created here (not in the cloudwatch module) so
# the task definition's awslogs driver can reference it directly without
# introducing a module dependency cycle (see modules/cloudwatch/main.tf).
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name_prefix}-app"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = "${local.name_prefix}-app-logs"
  }
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# ---------------------------------------------------------------------------
resource "aws_lb" "app" {
  # checkov:skip=CKV2_AWS_20:ALB intentionally serves plain HTTP in this demo/student-account deployment; no ACM certificate or custom domain is provisioned to avoid the cost/setup of a verified domain (see README Limitations). Enabling HTTPS/WAF is documented future work once a real domain is available.
  # checkov:skip=CKV2_AWS_28:ALB intentionally serves plain HTTP in this demo/student-account deployment; no ACM certificate or custom domain is provisioned to avoid the cost/setup of a verified domain (see README Limitations). Enabling HTTPS/WAF is documented future work once a real domain is available.
  # checkov:skip=CKV_AWS_150:Deletion protection is intentionally disabled in the dev environment so `terraform destroy` (documented in docs/deployment.md as the required cleanup step for a student AWS account) works without a manual override step.
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids

  drop_invalid_header_fields = true

  access_logs {
    bucket  = var.access_logs_bucket
    prefix  = "alb"
    enabled = true
  }

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  # checkov:skip=CKV_AWS_378:ALB intentionally serves plain HTTP in this demo/student-account deployment; no ACM certificate or custom domain is provisioned to avoid the cost/setup of a verified domain (see README Limitations). Enabling HTTPS/WAF is documented future work once a real domain is available.
  name        = "${local.name_prefix}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # required for awsvpc network mode (Fargate)

  health_check {
    path                = var.container_health_check_path
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = {
    Name = "${local.name_prefix}-tg"
  }
}

# HTTP listener. In a real deployment, add an HTTPS (443) listener with an
# ACM certificate and redirect this listener's traffic to it; omitted here
# to keep the demo deployable without a purchased/verified domain.
resource "aws_lb_listener" "http" {
  # checkov:skip=CKV_AWS_103:ALB intentionally serves plain HTTP in this demo/student-account deployment; no ACM certificate or custom domain is provisioned to avoid the cost/setup of a verified domain (see README Limitations). Enabling HTTPS/WAF is documented future work once a real domain is available.
  # checkov:skip=CKV_AWS_2:ALB intentionally serves plain HTTP in this demo/student-account deployment; no ACM certificate or custom domain is provisioned to avoid the cost/setup of a verified domain (see README Limitations). Enabling HTTPS/WAF is documented future work once a real domain is available.
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------------------
# Task definition and service
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = "${local.name_prefix}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.ecs_task_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = local.image
      essential = true

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      # Non-secret configuration passed directly; secrets are resolved from
      # Secrets Manager/SSM below so they never appear in the task
      # definition JSON, Terraform state plaintext diff, or CI logs.
      environment = [
        { name = "NODE_ENV", value = var.environment == "prod" ? "production" : var.environment },
        { name = "PORT", value = tostring(var.container_port) },
        { name = "AWS_REGION", value = var.aws_region },
      ]

      secrets = [
        { name = "JWT_SECRET", valueFrom = var.jwt_secret_arn },
        { name = "LOG_LEVEL", valueFrom = var.log_level_ssm_arn },
        { name = "RATE_LIMIT_MAX", valueFrom = var.rate_limit_ssm_arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }

      readonlyRootFilesystem = true

      # Exec form ("CMD", not "CMD-SHELL"): the runtime image is
      # gcr.io/distroless/nodejs22-debian12, which has no /bin/sh. ECS's
      # CMD-SHELL variant always wraps the command in `sh -c "..."`
      # regardless of what shell (if any) the image provides, so a
      # CMD-SHELL health check against this image fails every attempt
      # before node even starts — the container never gets marked healthy,
      # and the ECS deployment circuit breaker eventually trips. CMD runs
      # the argv list directly (node itself as argv[0]), which distroless's
      # nodejs image supports natively.
      healthCheck = {
        command     = ["CMD", "node", "-e", "require('http').get('http://127.0.0.1:${var.container_port}/health',(r)=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
    }
  ])

  tags = {
    Name = "${local.name_prefix}-app-taskdef"
  }
}

resource "aws_ecs_service" "app" {
  name            = "${local.name_prefix}-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_tasks_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # CodePipeline's ECS deploy action manages the task definition's image tag
  # after the first apply; ignore drift on it here so `terraform apply`
  # doesn't fight the pipeline over which image is "current".
  lifecycle {
    ignore_changes = [task_definition]
  }

  depends_on = [aws_lb_listener.http]

  tags = {
    Name = "${local.name_prefix}-app-service"
  }
}
