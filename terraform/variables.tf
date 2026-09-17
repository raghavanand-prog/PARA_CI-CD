variable "project_name" {
  description = "Short name used as a prefix for all resources (e.g. 'secure-cicd')."
  type        = string
  default     = "secure-cicd"
}

variable "environment" {
  description = "Deployment environment name (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ), hosting the ALB and NAT gateway."
  type        = list(string)
  default     = ["10.20.0.0/24", "10.20.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ), hosting the ECS Fargate tasks."
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24"]
}

variable "container_port" {
  description = "Port the application container listens on."
  type        = number
  default     = 3000
}

variable "ecs_task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU) — small on purpose for a student/demo AWS account."
  type        = string
  default     = "256"
}

variable "ecs_task_memory" {
  description = "Fargate task memory in MB — small on purpose for a student/demo AWS account."
  type        = string
  default     = "512"
}

variable "ecs_desired_count" {
  description = "Number of Fargate tasks to run."
  type        = number
  default     = 1
}

variable "github_owner" {
  description = "GitHub organization/user that owns the source repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without owner) containing the application source."
  type        = string
}

variable "github_branch" {
  description = "Branch CodePipeline tracks as the source of truth for deployments."
  type        = string
  default     = "main"
}

variable "codestar_connection_arn" {
  description = <<-EOT
    ARN of an existing AWS CodeStar Connections connection to GitHub.
    Create this once, out of band, via the AWS Console (Developer Tools ->
    Settings -> Connections) or `aws codestar-connections create-connection`,
    then complete the handshake authorizing GitHub access — Terraform cannot
    complete the GitHub OAuth handshake for you.
  EOT
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days for application and build logs. Defaults to 365 (1 year) to meet baseline audit-log retention practice; CloudWatch Logs storage cost at this project's log volume is negligible."
  type        = number
  default     = 365
}

variable "container_health_check_path" {
  description = "HTTP path the ALB target group uses for health checks."
  type        = string
  default     = "/health"
}

variable "alarm_notification_email" {
  description = "Optional email address subscribed to CloudWatch alarm notifications via SNS. Leave empty to skip creating a subscription."
  type        = string
  default     = ""
}

variable "dependency_scan_medium_threshold" {
  description = "Example of a policy-tunable value surfaced through Terraform outputs/tags for traceability with security/policy/security-policy.yaml. Purely informational at the infra layer."
  type        = number
  default     = 5
}
