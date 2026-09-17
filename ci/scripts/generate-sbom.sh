#!/usr/bin/env bash
# Generates a CycloneDX SBOM for the built image with Syft, if Syft is
# available. This is supply-chain hygiene (see docs/threat-model.md,
# "Supply Chain" section) — it is NOT currently a security-gate blocking
# check, so its absence never fails the build; it just means no SBOM is
# published for that run.
set -euo pipefail

IMAGE_REF="${1:?Usage: generate-sbom.sh <image:tag>}"
OUT_DIR="${2:-sbom}"
mkdir -p "$OUT_DIR"

if ! command -v syft >/dev/null 2>&1; then
  echo "WARNING: syft is not installed; skipping SBOM generation."
  echo "Install with: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin"
  exit 0
fi

echo "Generating CycloneDX SBOM for ${IMAGE_REF}"
syft "$IMAGE_REF" -o cyclonedx-json="${OUT_DIR}/sbom.cyclonedx.json"
syft "$IMAGE_REF" -o spdx-json="${OUT_DIR}/sbom.spdx.json"
echo "SBOM written to ${OUT_DIR}/sbom.cyclonedx.json and ${OUT_DIR}/sbom.spdx.json"
