# CodePipeline module: Source -> Build -> Deploy, three stages, no manual
# approval stage. The security gate that would traditionally sit in a
# manual "Approve" action instead runs INSIDE the Build stage
# (security-gate.sh, invoked from ci/buildspec.yml) — CodeBuild itself fails
# the stage if the gate fails, which stops the pipeline before Deploy ever
# runs. That is what "automated security gate" means in this project: the
# enforcement point is code, not a human clicking Approve.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

resource "aws_codepipeline" "app" {
  name     = "${local.name_prefix}-pipeline"
  role_arn = var.codepipeline_role_arn

  artifact_store {
    location = var.artifact_bucket
    type     = "S3"

    encryption_key {
      id   = var.kms_key_arn
      type = "KMS"
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = var.codestar_connection_arn
        FullRepositoryId = "${var.github_owner}/${var.github_repo}"
        BranchName       = var.github_branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "SecurityGatedBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = var.codebuild_project_name
      }
    }
  }

  # No Approval stage here by design (see module header comment). If a
  # human-in-the-loop gate is ever desired IN ADDITION to the automated one,
  # add a `category = "Approval", provider = "Manual"` action between Build
  # and Deploy — the automated gate should remain regardless.

  stage {
    name = "Deploy"

    action {
      name            = "DeployToECS"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ClusterName = var.ecs_cluster_name
        ServiceName = var.ecs_service_name
        FileName    = "imagedefinitions.json"
      }
    }
  }

  tags = {
    Name = "${local.name_prefix}-pipeline"
  }
}
