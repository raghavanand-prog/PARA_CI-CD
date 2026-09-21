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

  # var.availability_zones defaults to [] ("auto-detect"). A hardcoded
  # default AZ list (e.g. us-east-1a/b) breaks in any other region — AZ
  # names aren't portable across regions, and AWS rejects a subnet create
  # for an AZ that doesn't exist in the account's chosen region. Falling
  # back to the first 2 AZs the account actually has access to in this
  # region keeps this deployable anywhere without per-region tfvars edits.
  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

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
  availability_zones   = local.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  container_port       = var.container_port
  kms_key_arn          = module.security.kms_key_arn
  log_retention_days   = var.log_retention_days
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
  # checkov:skip=CKV2_AWS_62:Event notifications are not meaningful for this artifact bucket's usage pattern (CodePipeline-managed build artifacts only, no downstream event-driven consumers in this project).
  # checkov:skip=CKV_AWS_144:Cross-region replication adds real ongoing AWS cost inappropriate for a demo/student account artifact bucket; not warranted for CI build artifacts with no DR requirement.
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

# Expire noncurrent (superseded) object versions after 90 days. The bucket
# only ever holds transient CI build artifacts (source zips, imagedefinitions
# .json) — versioning exists for pipeline debuggability, not long-term
# retention, so unbounded version history is pure cost with no benefit for a
# student/demo AWS account.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # Explicit empty filter = applies to every object in the bucket. Newer
    # AWS provider versions warn (soon to error) if a rule has neither
    # `filter` nor `prefix` set, even though "apply to everything" was
    # previously the implicit default.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_logging" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "artifact-bucket/"
}

# ---------------------------------------------------------------------------
# Shared access-log destination bucket (S3 server access logs + ALB access
# logs land here). Kept as one small dedicated bucket rather than two, to
# stay simple — this is purely an observability sink, never read by the
# application or the pipeline.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "access_logs" {
  # checkov:skip=CKV_AWS_18:This IS the access-log destination bucket itself; logging a log bucket to itself would be circular and adds nothing.
  # checkov:skip=CKV2_AWS_62:Pure log-delivery sink; no downstream event-driven consumers.
  # checkov:skip=CKV_AWS_144:Access logs are low-value, high-volume data with no DR requirement for a demo/student account; cross-region replication would add real ongoing cost for no benefit.
  # checkov:skip=CKV_AWS_145:ALB access-log delivery only supports SSE-S3 (AES256), not SSE-KMS (see aws_s3_bucket_server_side_encryption_configuration.access_logs below) — this is an AWS ALB limitation, not a relaxed control; the bucket is still always encrypted at rest.
  bucket = "${local.name_prefix}-access-logs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${local.name_prefix}-access-logs"
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ALB access log delivery only supports SSE-S3 (AES256), not SSE-KMS, so
# this bucket intentionally does not use the shared CMK the way the artifact
# bucket does.
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire-old-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Allows the regional ELB/ALB log delivery service account to write access
# logs into this bucket, per AWS's documented ALB access-log bucket policy
# requirements. Scoped to PutObject on this bucket's prefix only.
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAlbLogDelivery"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.main.arn
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.access_logs.arn}/alb/*"
      },
      {
        Sid    = "AllowAlbLogDeliveryLogging"
        Effect = "Allow"
        Principal = {
          Service = "logdelivery.elasticloadbalancing.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.access_logs.arn}/alb/*"
      },
    ]
  })
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
  kms_key_arn                 = module.security.kms_key_arn
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
  access_logs_bucket          = aws_s3_bucket.access_logs.id
  container_port              = var.container_port
  container_health_check_path = var.container_health_check_path
  task_cpu                    = var.ecs_task_cpu
  task_memory                 = var.ecs_task_memory
  desired_count               = var.ecs_desired_count
  image_tag                   = var.image_tag
  ecr_repository_url          = module.ecr.repository_url
  ecs_task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  ecs_task_role_arn           = module.iam.ecs_task_role_arn
  kms_key_arn                 = module.security.kms_key_arn
  log_retention_days          = var.log_retention_days
  jwt_secret_arn              = module.security.jwt_secret_arn
  log_level_ssm_arn           = module.security.log_level_ssm_arn
  rate_limit_ssm_arn          = module.security.rate_limit_ssm_arn

  depends_on = [aws_s3_bucket_policy.access_logs]
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
  kms_key_arn             = module.security.kms_key_arn
  codestar_connection_arn = var.codestar_connection_arn
  github_owner            = var.github_owner
  github_repo             = var.github_repo
  github_branch           = var.github_branch
  codebuild_project_name  = module.codebuild.project_name
  ecs_cluster_name        = module.ecs.cluster_name
  ecs_service_name        = module.ecs.service_name
}
