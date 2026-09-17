# Networking module: VPC with public subnets (ALB, NAT gateway) and private
# subnets (ECS Fargate tasks — never exposed directly to the internet).

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  # checkov:skip=CKV_AWS_130:These are the PUBLIC subnets by design — the ALB and the NAT gateway's EIP both require a public IP, which is exactly what this Tier="public" subnet exists for. Private subnets (aws_subnet.private below) correctly do NOT set this.
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${local.name_prefix}-private-${var.availability_zones[count.index]}"
    Tier = "private"
  }
}

# Single NAT gateway (cost-optimized for a dev/student account). For
# production, use one NAT gateway per AZ for high availability.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${local.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# VPC flow logs — captures accepted/rejected IP traffic metadata for the
# whole VPC to CloudWatch Logs, encrypted with the shared CMK, for network
# forensics and anomaly detection.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/vpc/${local.name_prefix}-flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = "${local.name_prefix}-vpc-flow-logs"
  }
}

resource "aws_iam_role" "vpc_flow_logs" {
  name = "${local.name_prefix}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "${local.name_prefix}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteFlowLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
      },
    ]
  })
}

resource "aws_flow_log" "main" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow_logs.arn
  iam_role_arn         = aws_iam_role.vpc_flow_logs.arn

  tags = {
    Name = "${local.name_prefix}-vpc-flow-log"
  }
}

# Default security group of the VPC: intentionally left with no rules so it
# cannot be attached to anything and grant traffic — every real resource
# uses one of the explicit, purpose-built security groups below instead.
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-default-sg-restricted"
  }
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

# ALB: only accepts inbound HTTP/HTTPS from the internet. Egress is limited
# to the container port so the ALB can only reach the app, nothing else.
resource "aws_security_group" "alb" {
  # checkov:skip=CKV2_AWS_5:This SG IS attached — to aws_lb.app's security_groups in modules/ecs — via a module output/variable, which Checkov's graph check does not always resolve across module boundaries. See terraform/modules/ecs/main.tf.
  name        = "${local.name_prefix}-alb-sg"
  description = "Allows inbound HTTP/HTTPS from the internet to the ALB"
  vpc_id      = aws_vpc.main.id

  # checkov:skip=CKV_AWS_260:The ALB is intentionally internet-facing over HTTP for this demo (see the HTTPS-related skips on modules/ecs's listener/target group); this is the documented, deliberate entry point, not an unreviewed exposure.
  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "To ECS tasks on the app port only"
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

# ECS tasks: only accept traffic from the ALB security group, on the app
# port. No direct inbound access from the internet is possible — tasks sit
# in private subnets with no public IP.
resource "aws_security_group" "ecs_tasks" {
  # checkov:skip=CKV2_AWS_5:This SG IS attached — to the ECS service's network_configuration in modules/ecs — via a module output/variable, which Checkov's graph check does not always resolve across module boundaries. See terraform/modules/ecs/main.tf.
  name        = "${local.name_prefix}-ecs-tasks-sg"
  description = "Allows inbound traffic from the ALB only, to the app port"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "From ALB to app port"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # checkov:skip=CKV_AWS_382:Unrestricted egress is required for ECS tasks to reach ECR, CloudWatch, Secrets Manager, and package registries without provisioning a VPC endpoint for each; scoping every egress path is documented future work (see README Future improvements).
  egress {
    description = "Outbound for pulling images (via NAT), calling AWS APIs, and app dependencies"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-ecs-tasks-sg"
  }
}

# CodeBuild: runs inside the VPC only if needed for private resource access.
# Egress-only (no inbound needed) so CodeBuild can reach ECR/GitHub/etc.
resource "aws_security_group" "codebuild" {
  # checkov:skip=CKV2_AWS_5:This SG IS attached — to the CodeBuild project's vpc_config in modules/codebuild — via a module output/variable, which Checkov's graph check does not always resolve across module boundaries. See terraform/modules/codebuild/main.tf.
  name        = "${local.name_prefix}-codebuild-sg"
  description = "Egress-only security group for CodeBuild build environment"
  vpc_id      = aws_vpc.main.id

  # checkov:skip=CKV_AWS_382:Unrestricted egress is required for CodeBuild to reach ECR, CloudWatch, Secrets Manager, and package registries without provisioning a VPC endpoint for each; scoping every egress path is documented future work (see README Future improvements).
  egress {
    description = "Outbound for pulling deps, pushing images, calling AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-codebuild-sg"
  }
}
