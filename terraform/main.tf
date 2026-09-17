# Root module: wires all sub-modules together in dependency order.
#
#   security -> networking -> ecr -\
#                                    +-> iam -> codebuild -\
#   (root) artifact bucket ---------/                       +-> ecs -> cloudwatch -> codepipeline
#
# See terraform/environments/dev/main.tf for how a real environment invokes
# this root module with concrete variable values.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Shared security primitives (KMS key, JWT secret, SSM parameters)
# ---------------------------------------------------------------------------
module "security" {
  source = "./modules/security"

  project_name = var.project_name
  environment  = var.environment
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
module "networking" {
  source = "./modules/networking"

  project_name         = var.project_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  container_port       = var.container_port
}

# ---------------------------------------------------------------------------
# Container registry
# ---------------------------------------------------------------------------
module "ecr" {
  source = "./modules/ecr"

  project_name = var.project_name
  environment  = var.environment
  kms_key_arn  = module.security.kms_key_arn
}

# ---------------------------------------------------------------------------
# Pipeline artifact bucket (kept at root level, not inside a module, so both
# the iam and codepipeline modules can reference it without a module cycle)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket = "${local.name_prefix}-pipeline-artifacts-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${local.name_prefix}-pipeline-artifacts"
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = module.security.kms_key_arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# IAM roles (least privilege, one per actor)
# ---------------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  project_name        = var.project_name
  environment         = var.environment
  aws_region          = var.aws_region
  ecr_repository_arn  = module.ecr.repository_arn
  kms_key_arn         = module.security.kms_key_arn
  jwt_secret_arn      = module.security.jwt_secret_arn
  artifact_bucket_arn = aws_s3_bucket.artifacts.arn
  ssm_parameter_arns  = [module.security.log_level_ssm_arn, module.security.rate_limit_ssm_arn]
}

# ---------------------------------------------------------------------------
# CodeBuild: install -> lint -> test -> docker build -> scans -> gate -> push
# ---------------------------------------------------------------------------
module "cloudwatch" {
  source = "./modules/cloudwatch"

  project_name             = var.project_name
  environment              = var.environment
  log_retention_days       = var.log_retention_days
  kms_key_arn              = module.security.kms_key_arn
  ecs_cluster_name         = module.ecs.cluster_name
  ecs_service_name         = module.ecs.service_name
  alb_arn_suffix           = module.ecs.alb_arn_suffix
  target_group_arn_suffix  = module.ecs.target_group_arn_suffix
  alarm_notification_email = var.alarm_notification_email
}

module "codebuild" {
  source = "./modules/codebuild"

  project_name                = var.project_name
  environment                 = var.environment
  aws_region                  = var.aws_region
  codebuild_role_arn          = module.iam.codebuild_role_arn
  ecr_repository_url          = module.ecr.repository_url
  ecr_repository_name         = module.ecr.repository_name
  log_group_name              = module.cloudwatch.codebuild_log_group_name
  vpc_id                      = module.networking.vpc_id
  private_subnet_ids          = module.networking.private_subnet_ids
  codebuild_security_group_id = module.networking.codebuild_security_group_id
}

# ---------------------------------------------------------------------------
# ECS Fargate service behind an ALB
# ---------------------------------------------------------------------------
module "ecs" {
  source = "./modules/ecs"

  project_name                = var.project_name
  environment                 = var.environment
  aws_region                  = var.aws_region
  vpc_id                      = module.networking.vpc_id
  public_subnet_ids           = module.networking.public_subnet_ids
  private_subnet_ids          = module.networking.private_subnet_ids
  alb_security_group_id       = module.networking.alb_security_group_id
  ecs_tasks_security_group_id = module.networking.ecs_tasks_security_group_id
  container_port              = var.container_port
  container_health_check_path = var.container_health_check_path
  task_cpu                    = var.ecs_task_cpu
  task_memory                 = var.ecs_task_memory
  desired_count               = var.ecs_desired_count
  ecr_repository_url          = module.ecr.repository_url
  ecs_task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  ecs_task_role_arn           = module.iam.ecs_task_role_arn
  kms_key_arn                 = module.security.kms_key_arn
  log_retention_days          = var.log_retention_days
  jwt_secret_arn              = module.security.jwt_secret_arn
  log_level_ssm_arn           = module.security.log_level_ssm_arn
  rate_limit_ssm_arn          = module.security.rate_limit_ssm_arn
}

# ---------------------------------------------------------------------------
# CodePipeline: Source (GitHub) -> Build (gated) -> Deploy (ECS)
# ---------------------------------------------------------------------------
module "codepipeline" {
  source = "./modules/codepipeline"

  project_name            = var.project_name
  environment             = var.environment
  codepipeline_role_arn   = module.iam.codepipeline_role_arn
  artifact_bucket         = aws_s3_bucket.artifacts.bucket
  codestar_connection_arn = var.codestar_connection_arn
  github_owner            = var.github_owner
  github_repo             = var.github_repo
  github_branch           = var.github_branch
  codebuild_project_name  = module.codebuild.project_name
  ecs_cluster_name        = module.ecs.cluster_name
  ecs_service_name        = module.ecs.service_name
}
