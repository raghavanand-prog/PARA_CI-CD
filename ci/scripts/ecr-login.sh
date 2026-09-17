#!/usr/bin/env bash
# Logs the local Docker daemon in to the account's ECR registry.
# Requires AWS_REGION_NAME and ECR_REPOSITORY_URL to be set in the
# environment (CodeBuild sets these from the CodeBuild project's
# environment variables — see terraform/modules/codebuild).
set -euo pipefail

: "${AWS_REGION_NAME:?AWS_REGION_NAME must be set}"
: "${ECR_REPOSITORY_URL:?ECR_REPOSITORY_URL must be set}"

REGISTRY_HOST="${ECR_REPOSITORY_URL%%/*}"

echo "Logging in to ECR registry: ${REGISTRY_HOST}"
aws ecr get-login-password --region "$AWS_REGION_NAME" \
  | docker login --username AWS --password-stdin "$REGISTRY_HOST"

echo "ECR login successful."
