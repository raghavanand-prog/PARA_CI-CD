variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "kms_key_arn" {
  description = "KMS key used to encrypt images at rest in ECR."
  type        = string
}

variable "max_image_count" {
  description = "Maximum number of tagged images retained before older ones are expired."
  type        = number
  default     = 20
}
