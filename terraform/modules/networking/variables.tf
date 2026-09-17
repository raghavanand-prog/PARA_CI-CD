variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  type = list(string)
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "container_port" {
  type = number
}

variable "kms_key_arn" {
  description = "CMK used to encrypt the VPC flow log CloudWatch Logs group."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for VPC flow logs."
  type        = number
  default     = 30
}
