# Dev environment entry point. This is what you actually run
# `terraform init/plan/apply` from for a day-to-day dev deployment; it wires
# the root module with dev-sized defaults and its own state file.
#
#   cd terraform/environments/dev
#   cp backend.tf.example backend.tf    # fill in your bucket/table
#   terraform init
#   terraform plan  -var-file=terraform.tfvars
#   terraform apply -var-file=terraform.tfvars

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

module "app" {
  source = "../.."

  project_name = var.project_name
  environment  = "dev"
  aws_region   = var.aws_region

  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  container_port              = var.container_port
  container_health_check_path = var.container_health_check_path

  # Dev-sized: smallest Fargate task size, single task, single NAT gateway —
  # intentionally cheap enough to run in a student/free-tier AWS account.
  ecs_task_cpu      = "256"
  ecs_task_memory   = "512"
  ecs_desired_count = 1

  github_owner            = var.github_owner
  github_repo             = var.github_repo
  github_branch           = var.github_branch
  codestar_connection_arn = var.codestar_connection_arn

  log_retention_days       = var.log_retention_days
  alarm_notification_email = var.alarm_notification_email
}
