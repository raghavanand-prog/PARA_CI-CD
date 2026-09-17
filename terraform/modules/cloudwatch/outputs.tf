output "codebuild_log_group_name" {
  value = aws_cloudwatch_log_group.codebuild.name
}

output "codepipeline_log_group_name" {
  value = aws_cloudwatch_log_group.codepipeline.name
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
