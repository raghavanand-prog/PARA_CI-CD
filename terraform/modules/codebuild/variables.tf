variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "codebuild_role_arn" {
  type = string
}

variable "ecr_repository_url" {
  type = string
}

variable "ecr_repository_name" {
  type = string
}

variable "log_group_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "codebuild_security_group_id" {
  type = string
}

variable "buildspec_path" {
  description = "Path (relative to the source repo root) to the buildspec CodeBuild runs."
  type        = string
  default     = "ci/buildspec.yml"
}
