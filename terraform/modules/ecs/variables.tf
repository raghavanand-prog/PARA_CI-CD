variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "alb_security_group_id" {
  type = string
}

variable "access_logs_bucket" {
  description = "S3 bucket ALB access logs are delivered to."
  type        = string
}

variable "ecs_tasks_security_group_id" {
  type = string
}

variable "container_port" {
  type = number
}

variable "container_health_check_path" {
  type = string
}

variable "task_cpu" {
  type = string
}

variable "task_memory" {
  type = string
}

variable "desired_count" {
  type = number
}

variable "ecr_repository_url" {
  type = string
}

# The pipeline updates the running task definition's image tag after each
# gate-approved build; Terraform seeds it with a safe default so the very
# first `apply` (before any image has been pushed) does not fail. CodeDeploy
# ECS action (via CodePipeline) owns the image tag after that.
variable "image_tag" {
  type    = string
  default = "initial"
}

variable "ecs_task_execution_role_arn" {
  type = string
}

variable "ecs_task_role_arn" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "log_retention_days" {
  type = number
}

variable "jwt_secret_arn" {
  type = string
}

variable "log_level_ssm_arn" {
  type = string
}

variable "rate_limit_ssm_arn" {
  type = string
}
