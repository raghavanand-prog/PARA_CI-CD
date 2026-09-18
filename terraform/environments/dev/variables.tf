variable "project_name" {
  type    = string
  default = "secure-cicd"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = []
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.0.0/24", "10.20.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.10.0/24", "10.20.11.0/24"]
}

variable "container_port" {
  type    = number
  default = 3000
}

variable "container_health_check_path" {
  type    = string
  default = "/health"
}

variable "github_owner" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "github_branch" {
  type    = string
  default = "main"
}

variable "codestar_connection_arn" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 365
}

variable "alarm_notification_email" {
  type    = string
  default = ""
}
