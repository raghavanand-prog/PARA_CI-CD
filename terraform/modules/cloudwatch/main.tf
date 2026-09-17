# CloudWatch module: log groups for CodeBuild and CodePipeline, plus a
# handful of alarms covering the signals that matter most for a small
# Fargate service — task health, error rate, latency.
#
# The application's own log group is created inside modules/ecs instead of
# here: the ECS task definition's awslogs driver references it directly, and
# creating it there (rather than importing it from this module) avoids a
# module dependency cycle, since this module's alarms depend on ECS/ALB
# attributes that only exist after the ecs module has run.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/codebuild/${local.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = "${local.name_prefix}-codebuild-logs"
  }
}

resource "aws_cloudwatch_log_group" "codepipeline" {
  name              = "/codepipeline/${local.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = "${local.name_prefix}-codepipeline-logs"
  }
}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name              = "${local.name_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_notification_email
}

# Fires if the ECS service has fewer running tasks than desired for 3
# consecutive minutes — usually means the app is crash-looping or the
# health check is failing.
resource "aws_cloudwatch_metric_alarm" "ecs_running_task_count_low" {
  alarm_name          = "${local.name_prefix}-ecs-running-tasks-low"
  alarm_description   = "ECS service has fewer running tasks than desired"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 3
  period              = 60
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# Fires on a sustained rise in ALB 5xx responses — signals the app is
# erroring out even though tasks may still be "running".
resource "aws_cloudwatch_metric_alarm" "alb_5xx_high" {
  alarm_name          = "${local.name_prefix}-alb-5xx-high"
  alarm_description   = "ALB target 5xx error rate is elevated"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 10
  evaluation_periods  = 2
  period              = 60
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# Fires when p95 target response time degrades noticeably.
resource "aws_cloudwatch_metric_alarm" "alb_latency_high" {
  alarm_name          = "${local.name_prefix}-alb-latency-high"
  alarm_description   = "ALB target response time p95 is elevated"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 2
  evaluation_periods  = 3
  period              = 60
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
