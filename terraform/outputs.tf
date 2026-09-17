output "vpc_id" {
  value = module.networking.vpc_id
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "alb_dns_name" {
  description = "Public URL of the load balancer fronting the ECS service, e.g. http://<this>/health"
  value       = module.ecs.alb_dns_name
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_name" {
  value = module.ecs.service_name
}

output "codepipeline_name" {
  value = module.codepipeline.pipeline_name
}

output "codebuild_project_name" {
  value = module.codebuild.project_name
}

output "artifact_bucket_name" {
  value = aws_s3_bucket.artifacts.bucket
}

output "kms_key_arn" {
  value = module.security.kms_key_arn
}

output "app_log_group_name" {
  value = module.ecs.app_log_group_name
}

output "alerts_topic_arn" {
  value = module.cloudwatch.alerts_topic_arn
}
