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

  # Explicit key policy (replacing the implicit/default one Checkov flags):
  # the account root is granted full administrative control over the key.
  # This is what actually makes the rest of this project work — IAM policies
  # in modules/iam grant specific principals kms:Decrypt/Encrypt/
  # GenerateDataKey on this key's ARN, and AWS KMS only honors those IAM
  # grants when the key policy delegates management to the account (root)
  # the way this statement does; every principal's actual usage is still
  # governed by its own least-privilege IAM policy (see modules/iam), this
  # key policy is only the administrative delegation layer.
  #
  # A second, separate statement grants the CloudWatch Logs service
  # principal permission to use this key: unlike ordinary account
  # principals, an AWS *service* (logs.amazonaws.com here) is not covered
  # by the root-account delegation above — CloudWatch Logs assumes its own
  # service context when creating a log group with a customer-managed KMS
  # key, and AWS rejects `CreateLogGroup` with AccessDeniedException unless
  # the key's own policy explicitly allows that service principal. Scoped
  # via the EncryptionContext condition to only this account's log groups.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowRootAccountFullAdmin"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogsServiceUsage"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      },
    ]
  })

  tags = {
    Name = "${local.name_prefix}-kms"
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

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
  # checkov:skip=CKV2_AWS_57:Automatic rotation intentionally deferred; manual rotation steps are documented in docs/troubleshooting.md (see README Limitations: "No automatic Secrets Manager rotation").
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
# SecureString (encrypted with the shared CMK) even though the values carry
# no confidentiality requirement — this is the actual gap Checkov catches
# (unencrypted SSM parameters), and encrypting is free/zero-cost here, so
# there is no reason to accept it as a trade-off.
resource "aws_ssm_parameter" "log_level" {
  name   = "/${local.name_prefix}/log-level"
  type   = "SecureString"
  value  = "info"
  key_id = aws_kms_key.main.arn

  tags = {
    Name = "${local.name_prefix}-log-level"
  }
}

resource "aws_ssm_parameter" "rate_limit_max" {
  name   = "/${local.name_prefix}/rate-limit-max"
  type   = "SecureString"
  value  = "100"
  key_id = aws_kms_key.main.arn

  tags = {
    Name = "${local.name_prefix}-rate-limit-max"
  }
}
