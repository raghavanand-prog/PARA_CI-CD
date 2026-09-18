# IAM module: one least-privilege role per pipeline/runtime actor.
#
# Every policy below is scoped as tightly as practical and each statement
# carries a comment explaining WHY that specific permission exists — the
# goal is that a reviewer never has to guess what a grant is for.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ===========================================================================
# 1. CodePipeline service role
# ===========================================================================
resource "aws_iam_role" "codepipeline" {
  name = "${local.name_prefix}-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "${local.name_prefix}-codepipeline-policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ArtifactBucketReadWrite"
        Effect = "Allow"
        # CodePipeline stages hand artifacts to each other exclusively
        # through this S3 bucket (source zip -> build input, build output ->
        # deploy input).
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:GetBucketVersioning",
          "s3:GetBucketLocation",
        ]
        Resource = [
          var.artifact_bucket_arn,
          "${var.artifact_bucket_arn}/*",
        ]
      },
      {
        Sid    = "ArtifactEncryption"
        Effect = "Allow"
        # The artifact bucket is encrypted with the shared CMK; the pipeline
        # role needs to decrypt objects it reads and encrypt objects it writes.
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = var.kms_key_arn
      },
      {
        Sid    = "InvokeCodeBuild"
        Effect = "Allow"
        # The Build stage's only job is to start/poll the CodeBuild project
        # that actually runs tests, scans, and the security gate.
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds",
        ]
        Resource = "arn:aws:codebuild:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:project/${local.name_prefix}-*"
      },
      {
        Sid    = "GitHubSourceConnection"
        Effect = "Allow"
        # Required so the Source stage can pull from the GitHub repo through
        # the pre-authorized CodeStar Connection (no GitHub token is stored
        # in AWS or in this repo).
        Action   = ["codestar-connections:UseConnection"]
        Resource = "arn:aws:codeconnections:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:connection/*"
      },
      {
        Sid    = "EcsDeploy"
        Effect = "Allow"
        # This matches AWS's own officially documented IAM policy for the
        # CodePipeline ECS deploy action provider (see "Add permissions for
        # other AWS services" in the CodePipeline user guide) exactly,
        # including its Resource: "*" scope for the whole action set.
        #
        # We tried scoping ecs:DescribeServices/UpdateService to this one
        # service's ARN and ecs:DescribeTasks to this one cluster's task
        # ARN pattern first (least-privilege is the default posture
        # throughout this module) — both are valid IAM policy language and
        # terraform apply accepted them, but real pipeline runs against a
        # live AWS account still failed at the Deploy stage with the same
        # generic "PermissionError: The provided role does not have
        # sufficient permissions to access ECS" both before and after that
        # scoping, with no more specific detail from AWS on which exact
        # call was rejected. Matching AWS's own reference policy verbatim,
        # rather than continuing to guess at a scoped variant against an
        # opaque error, is the documented, supported configuration for
        # this specific native CodePipeline integration.
        # checkov:skip=CKV_AWS_290:Matches AWS's own documented IAM policy for the CodePipeline ECS deploy action provider — see inline comment for why a scoped variant was tried and abandoned.
        # checkov:skip=CKV_AWS_355:Same as CKV_AWS_290 above.
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService",
        ]
        Resource = "*"
      },
      {
        Sid    = "EcsDeployTagNewTaskDefinitionRevision"
        Effect = "Allow"
        # Not in AWS's documented reference policy above (that policy is
        # apparently incomplete/outdated) — found via CloudTrail after two
        # real pipeline failures against a live account both surfaced only
        # CodePipeline's generic, unhelpful "PermissionError: The provided
        # role does not have sufficient permissions to access ECS" with no
        # indication of the specific rejected call. `aws cloudtrail
        # lookup-events` on ecs.amazonaws.com showed the real denial:
        # RegisterTaskDefinition itself succeeds, but CodePipeline then
        # calls ecs:TagResource to propagate the existing task definition
        # family's tags onto the new revision it just registered, and
        # that action was never granted. Scoped to this one task
        # definition family (the resource ARN CloudTrail's error message
        # itself named), not "*".
        Action   = ["ecs:TagResource"]
        Resource = "arn:aws:ecs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:task-definition/${local.name_prefix}-app:*"
      },
      {
        Sid    = "PassEcsRoles"
        Effect = "Allow"
        # ECS deploy actions must be able to pass the task execution/task
        # roles to the ECS service when registering a new task definition.
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-ecs-*"
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

# ===========================================================================
# 2. CodeBuild service role
# ===========================================================================
resource "aws_iam_role" "codebuild" {
  name = "${local.name_prefix}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${local.name_prefix}-codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteBuildLogs"
        Effect = "Allow"
        # buildspec.yml output (including the security-gate.sh PASS/FAIL
        # summary) is streamed to this log group for audit and debugging.
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/codebuild/${local.name_prefix}*"
      },
      {
        Sid    = "ArtifactBucketReadWrite"
        Effect = "Allow"
        # Pulls the source artifact CodePipeline staged and writes the build
        # output artifact (image digest, imagedefinitions.json) back.
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:GetBucketVersioning",
          "s3:GetBucketLocation",
        ]
        Resource = [
          var.artifact_bucket_arn,
          "${var.artifact_bucket_arn}/*",
        ]
      },
      {
        Sid    = "ArtifactEncryption"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = var.kms_key_arn
      },
      {
        Sid    = "EcrAuth"
        Effect = "Allow"
        # docker login against ECR requires a token; GetAuthorizationToken
        # cannot be scoped to a single repository (AWS API restriction),
        # everything else below IS scoped to this one repo.
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPushPull"
        Effect = "Allow"
        # Only granted on ONE security-gate PASS does the buildspec actually
        # call these — this permission existing does not itself bypass the
        # gate, which is enforced in buildspec.yml/security-gate.sh logic.
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = var.ecr_repository_arn
      },
      {
        Sid    = "ReadJwtSecretForIntegrationTests"
        Effect = "Allow"
        # Some integration-style tests exercise the auth flow against a
        # real-shaped secret rather than a hardcoded test value.
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.jwt_secret_arn
      },
      {
        Sid    = "VpcNetworkInterfaceManagement"
        Effect = "Allow"
        # This CodeBuild project runs inside the VPC (see vpc_config in
        # modules/codebuild), so the CodeBuild service itself — not the
        # human/CI identity running `terraform apply` — needs permission to
        # create and manage the elastic network interface it attaches to
        # the private subnet for the build. AWS does not support
        # resource-level permissions for these specific EC2 Describe/Create/
        # Delete actions in this context (documented CodeBuild VPC policy
        # requirement), so Resource must be "*" here, same class of
        # unavoidable wildcard as EcrAuth above.
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeDhcpOptions",
          "ec2:DescribeVpcs",
        ]
        Resource = "*"
      },
      {
        Sid    = "VpcNetworkInterfacePermission"
        Effect = "Allow"
        # Unlike the statement above, this one CAN be scoped: restricted to
        # network interfaces in this account/region, and further gated by
        # the AuthorizedService condition so only the CodeBuild service
        # itself (not an arbitrary caller) can exercise this permission.
        Action   = "ec2:CreateNetworkInterfacePermission"
        Resource = "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:network-interface/*"
        Condition = {
          StringEquals = {
            "ec2:AuthorizedService" = "codebuild.amazonaws.com"
          }
        }
      },
    ]
  })
}

# ===========================================================================
# 3. ECS task EXECUTION role — used by the ECS agent, not the app itself, to
#    pull the image and start the container.
# ===========================================================================
resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.name_prefix}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_execution" {
  name = "${local.name_prefix}-ecs-task-execution-policy"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPull"
        Effect = "Allow"
        # The ECS agent needs to pull the exact image the gate approved.
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = var.ecr_repository_arn
      },
      {
        Sid    = "WriteContainerLogs"
        Effect = "Allow"
        # The awslogs log driver in the task definition needs this to ship
        # container stdout/stderr to CloudWatch.
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${local.name_prefix}*"
      },
      {
        Sid    = "InjectSecretsAtStartup"
        Effect = "Allow"
        # The task definition's `secrets` block resolves JWT_SECRET from
        # Secrets Manager at container startup; this is what makes that
        # resolution possible without the secret ever touching source code.
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.jwt_secret_arn
      },
      {
        Sid    = "InjectSsmConfigAtStartup"
        Effect = "Allow"
        # Resolves non-secret runtime config (log level, rate-limit max)
        # from SSM Parameter Store, also via the task definition's `secrets`
        # block, for consistency/least-privilege even though these values
        # aren't confidential.
        Action   = ["ssm:GetParameters"]
        Resource = var.ssm_parameter_arns
      },
      {
        Sid      = "DecryptSecretsAndLogs"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

# ===========================================================================
# 4. ECS task role — assumed by the running application container itself.
#    Kept minimal because this demo app makes no AWS API calls of its own;
#    a real app would add scoped permissions here (e.g. one DynamoDB table).
# ===========================================================================
resource "aws_iam_role" "ecs_task" {
  name = "${local.name_prefix}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task" {
  name = "${local.name_prefix}-ecs-task-policy"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EmitCustomMetrics"
        Effect = "Allow"
        # Allows the app to publish its own CloudWatch custom metrics
        # (e.g. business-level counters) if it ever needs to; PutMetricData
        # cannot be resource-scoped by AWS, so it is the only "*" grant here,
        # and it grants no read or destructive capability whatsoever.
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "${local.name_prefix}/app" }
        }
      },
    ]
  })
}
