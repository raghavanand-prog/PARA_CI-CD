# CodeBuild module: one project that runs install -> lint -> unit tests ->
# docker build -> ALL security scans -> security-gate.sh -> (on PASS) ECR
# push. This is the automated enforcement point — there is deliberately no
# manual "approve to deploy" action anywhere in this pipeline; the security
# gate itself is the approval mechanism.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

resource "aws_codebuild_project" "app" {
  name          = "${local.name_prefix}-build"
  description   = "Builds, security-scans (SAST/SCA/secrets/IaC/container), gates, and pushes the app image"
  service_role  = var.codebuild_role_arn
  build_timeout = 30 # minutes; generous enough for full scan suite + docker build

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # required to run `docker build` inside CodeBuild

    environment_variable {
      name  = "ECR_REPOSITORY_URL"
      value = var.ecr_repository_url
    }

    environment_variable {
      name  = "ECR_REPOSITORY_NAME"
      value = var.ecr_repository_name
    }

    environment_variable {
      name  = "AWS_REGION_NAME"
      value = var.aws_region
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = var.buildspec_path
  }

  logs_config {
    cloudwatch_logs {
      group_name = var.log_group_name
    }
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = var.private_subnet_ids
    security_group_ids = [var.codebuild_security_group_id]
  }

  tags = {
    Name = "${local.name_prefix}-build"
  }
}
