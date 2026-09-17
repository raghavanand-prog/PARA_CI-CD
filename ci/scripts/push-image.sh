#!/usr/bin/env bash
# Tags and pushes the locally built image to ECR, then writes
# imagedefinitions.json — the file AWS CodePipeline's ECS deploy action
# expects, mapping container name -> image URI (with digest) to deploy.
#
# This script only runs AFTER security-gate.sh has exited 0 (see
# ci/buildspec.yml) — pushing here does not bypass the gate, it is the
# gate's reward for passing.
set -euo pipefail

: "${ECR_REPOSITORY_URL:?ECR_REPOSITORY_URL must be set}"
: "${IMAGE_TAG:?IMAGE_TAG must be set}"
: "${LOCAL_IMAGE:?LOCAL_IMAGE must be set}"
CONTAINER_NAME="${CONTAINER_NAME:-app}"

REMOTE_IMAGE="${ECR_REPOSITORY_URL}:${IMAGE_TAG}"

echo "Tagging ${LOCAL_IMAGE} as ${REMOTE_IMAGE}"
docker tag "$LOCAL_IMAGE" "$REMOTE_IMAGE"

echo "Pushing ${REMOTE_IMAGE}"
docker push "$REMOTE_IMAGE"

DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$REMOTE_IMAGE" 2>/dev/null || echo "")

if [[ -n "$DIGEST" ]]; then
  IMAGE_URI="$DIGEST"
  echo "Resolved digest-pinned image: ${IMAGE_URI}"
else
  IMAGE_URI="$REMOTE_IMAGE"
  echo "WARNING: could not resolve digest; falling back to tag reference ${IMAGE_URI}"
fi

cat > imagedefinitions.json <<EOF
[
  {
    "name": "${CONTAINER_NAME}",
    "imageUri": "${IMAGE_URI}"
  }
]
EOF

echo "Wrote imagedefinitions.json:"
cat imagedefinitions.json
