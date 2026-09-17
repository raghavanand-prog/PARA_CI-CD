# Troubleshooting

## Installing the security scanners locally

Every `security/scripts/run-*.sh` script fails loudly (writes a
`status: "tool_missing"` report and exits 1) rather than silently skipping
itself when its tool isn't installed — and the gate fails closed on that.
To get real (non-`tool_missing`) results locally, install:

```bash
# Semgrep (SAST)
pip install semgrep
# or: brew install semgrep

# OWASP Dependency-Check (optional, deeper SCA than npm audit alone)
# https://jeremylong.github.io/DependencyCheck/dependency-check-cli/
brew install dependency-check
# or download the CLI zip from the GitHub releases page and add it to PATH

# Gitleaks (secret scanning)
brew install gitleaks
# or: curl -sSfL https://raw.githubusercontent.com/gitleaks/gitleaks/master/scripts/install.sh | sh -s -- -b /usr/local/bin

# Checkov (IaC scanning)
pip install checkov

# Trivy (container scanning)
brew install trivy
# or: curl -sSfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

# Syft (SBOM generation, optional/non-blocking)
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
```

`npm audit` needs no separate install — it ships with npm, and
`run-dependency-scan.sh` uses it automatically whenever `app/package.json`
exists.

## `security-gate.sh` exits 3 immediately

Exit code 3 means the gate itself could not run — check, in order:
1. Are `jq` and `yq` installed? (`command -v jq yq`)
2. Does `security/policy/security-policy.yaml` exist and parse as valid
   YAML? (`yq '.' security/policy/security-policy.yaml`)
3. Does it have all six required top-level sections (`version`, `sast`,
   `dependencies`, `secrets`, `iac`, `container`, `gate`)?

This is by design — a broken policy file must never be interpreted as "no
policy, so allow everything."

## `security-gate.sh` says every category is missing/FAIL

Have you actually run the scan scripts first? The gate only *reads*
reports; it does not generate them. Run, in order:

```bash
bash security/scripts/run-sast.sh app/src
bash security/scripts/run-dependency-scan.sh app
bash security/scripts/run-secret-scan.sh
bash security/scripts/run-iac-scan.sh terraform
bash security/scripts/run-container-scan.sh <your-image:tag>   # needs a built image
bash security/scripts/security-gate.sh
```

`make security` runs the first four for you (container scanning needs an
image reference, so it's separate — see `make docker-scan`).

## `yq` behaves differently / `-o=json` unknown flag

There are two unrelated tools both called `yq`:
- **mikefarah/yq** (Go): supports `yq -o=json '.' file.yaml`.
- **kislyuk/yq** (Python, wraps `jq`): emits JSON by default from
  `yq '.' file.yaml`, and does not understand `-o=json`.

`security-gate.sh` detects which one is on `PATH` (via `yq --help`) and
uses the right invocation for either, so this should be transparent — if
you see an "Unknown option" error from `jq` when running the gate, you
likely have a third, unexpected `yq` variant; `pip install yq` (the
kislyuk one) is what this project was built and tested against.

## Docker build fails / `docker: command not found`

The Dockerfile at `app/Dockerfile` requires a working Docker daemon.
- On a machine without Docker access, you can still run `make test` and
  `make lint` (they don't need Docker) and `make security` for the
  non-container scanners.
- CodeBuild always has Docker available (via `privileged_mode = true` in
  `terraform/modules/codebuild`) — the AWS pipeline build is unaffected by
  local Docker availability.

## `terraform validate` fails with a provider download error

If `registry.terraform.io` is unreachable from your network (corporate
proxy, air-gapped CI runner, etc.), download the provider zip directly
from `releases.hashicorp.com/terraform-provider-aws/<version>/` and
`terraform-provider-random/<version>/`, unpack it into a local filesystem
mirror, and point Terraform at it via a `provider_installation` block in
`~/.terraformrc`:

```hcl
provider_installation {
  filesystem_mirror {
    path    = "/path/to/your/mirror"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
```

This is exactly how this repository's own `terraform fmt`/`validate`/`plan`
were exercised in the sandbox this project was built in, where the
registry itself was not reachable but direct HTTPS downloads from
`releases.hashicorp.com` were.

## CodePipeline Source stage fails / stuck "pending"

- Confirm the CodeStar Connection status is **Available**, not
  **Pending** — a newly created connection requires you to complete the
  GitHub authorization handshake in the AWS Console before it can be used
  (see `deployment.md` section 2). Terraform can create the connection
  resource, but cannot complete this interactive step for you.
- Confirm `github_owner`/`github_repo`/`github_branch` in
  `terraform.tfvars` exactly match the real repository (case-sensitive).

## ECS service won't stabilize / tasks keep restarting

1. Check the app log group in CloudWatch:
   `/ecs/<project>-<environment>-app`.
2. Common causes: `JWT_SECRET` couldn't be resolved from Secrets Manager
   (check the ECS task execution role has `secretsmanager:GetSecretValue`
   on the right ARN — see `terraform/modules/iam`), or the health check
   path (`/health`) doesn't match what the app actually serves (it does,
   by default — check for local edits).
3. `aws ecs describe-services --cluster <cluster> --services <service>`
   surfaces the most recent deployment failure reason directly.

## Rotating the JWT secret

This repo does not wire up automatic Secrets Manager rotation (documented
as a future improvement in the README). To rotate manually:

```bash
aws secretsmanager put-secret-value \
  --secret-id <project>-<environment>/jwt-secret \
  --secret-string "$(openssl rand -base64 48)"

aws ecs update-service --cluster <cluster> --service <service> --force-new-deployment
```

Rotating invalidates all previously issued JWTs (by design — they were
signed with the old secret).
