# Security module: the shared KMS key used to encrypt data at rest
# (ECR images, CloudWatch Logs, Secrets Manager, S3 artifact bucket) and the
# Secrets Manager secret holding the application's JWT signing key. Nothing
# in this module, or anywhere else in this repository, contains a real
# secret value — Terraform generates a random one at apply time and the
# application reads it at runtime via the ECS task definition's `secrets`
# block (see modules/ecs), never from a file or environment default.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

resource "aws_kms_key" "main" {
  description             = "CMK for ${local.name_prefix}: encrypts ECR images, CloudWatch Logs, Secrets Manager, and the CodePipeline artifact bucket"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${local.name_prefix}-kms"
  }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}

# Randomly generated at apply time — never hardcoded, never checked into
# source control. Rotate by running `terraform apply -replace` against this
# resource, or wire in aws_secretsmanager_secret_rotation for automatic
# rotation in a production deployment.
resource "random_password" "jwt_secret" {
  length  = 64
  special = true
}

resource "aws_secretsmanager_secret" "jwt_secret" {
  name        = "${local.name_prefix}/jwt-secret"
  description = "JWT signing secret for the demo API, injected into the ECS task at runtime"
  kms_key_id  = aws_kms_key.main.arn

  tags = {
    Name = "${local.name_prefix}-jwt-secret"
  }
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id     = aws_secretsmanager_secret.jwt_secret.id
  secret_string = random_password.jwt_secret.result
}

# Non-secret runtime configuration goes through SSM Parameter Store rather
# than Secrets Manager, since it carries no confidentiality requirement and
# SSM standard parameters are free.
resource "aws_ssm_parameter" "log_level" {
  name  = "/${local.name_prefix}/log-level"
  type  = "String"
  value = "info"

  tags = {
    Name = "${local.name_prefix}-log-level"
  }
}

resource "aws_ssm_parameter" "rate_limit_max" {
  name  = "/${local.name_prefix}/rate-limit-max"
  type  = "String"
  value = "100"

  tags = {
    Name = "${local.name_prefix}-rate-limit-max"
  }
}
