variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "ecr_repository_arn" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "jwt_secret_arn" {
  type = string
}

variable "artifact_bucket_arn" {
  type = string
}

variable "ssm_parameter_arns" {
  description = "SSM Parameter Store ARNs the ECS task execution role must be able to resolve at container startup (non-secret runtime config injected via the task definition's `secrets` block)."
  type        = list(string)
}
