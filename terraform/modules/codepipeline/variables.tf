variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "codepipeline_role_arn" {
  type = string
}

variable "artifact_bucket" {
  type = string
}

variable "kms_key_arn" {
  description = "CMK used to encrypt the CodePipeline artifact store."
  type        = string
}

variable "codestar_connection_arn" {
  type = string
}

variable "github_owner" {
  type = string
}

variable "github_repo" {
  type = string
}

variable "github_branch" {
  type = string
}

variable "codebuild_project_name" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}
