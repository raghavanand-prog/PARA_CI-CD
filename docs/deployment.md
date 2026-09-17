# Deployment Guide

## 1. Prerequisites

- An AWS account (a student/free-tier account is sufficient — see the cost
  notes below).
- AWS CLI v2, configured with credentials that can create IAM roles, VPCs,
  ECS/ECR/CodePipeline/CodeBuild resources, KMS keys, Secrets Manager
  secrets, and S3 buckets.
- Terraform >= 1.5.0.
- Docker (for local builds/testing; CodeBuild builds images in AWS itself).
- A GitHub account and a fork/clone of this repository.
- Node.js >= 20 (for local app development).

## 2. GitHub setup

1. Push this repository to your own GitHub account/org (or use it as-is if
   you already have write access).
2. In the AWS Console: **Developer Tools -> Settings -> Connections ->
   Create connection**, provider **GitHub**. Complete the OAuth handshake
   in the browser prompt — this is the one step Terraform cannot do for
   you, because it requires interactive GitHub authorization.
3. Copy the resulting connection's ARN
   (`arn:aws:codeconnections:<region>:<account-id>:connection/<id>`) — you
   will put this in `terraform.tfvars` as `codestar_connection_arn`.
4. (Recommended) In your GitHub repo's **Settings -> Branches**, add a
   branch protection rule for `main` requiring the `security-gate` status
   check (from `.github/workflows/security-gate.yml`) to pass before
   merging.

## 3. Terraform state backend (one-time, per AWS account)

The backend cannot create its own storage, so create it first, by hand:

```bash
aws s3api create-bucket \
  --bucket <your-unique-tfstate-bucket-name> \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket <your-unique-tfstate-bucket-name> \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket <your-unique-tfstate-bucket-name> \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws dynamodb create-table \
  --table-name <your-unique-tf-lock-table-name> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

## 4. Terraform deployment

```bash
cd terraform/environments/dev

cp backend.tf.example backend.tf
# edit backend.tf: set bucket, dynamodb_table, region

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set github_owner, github_repo, codestar_connection_arn,
# and optionally alarm_notification_email

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

`terraform apply` provisions, in order: the KMS key and Secrets
Manager/SSM entries, the VPC/subnets/security groups, the ECR repository,
the S3 pipeline-artifact bucket, all four IAM roles, the ECS
cluster/ALB/service (seeded with a placeholder image tag — the first real
image arrives via the pipeline), the CloudWatch log groups/alarms, the
CodeBuild project, and finally the CodePipeline itself.

After `apply` finishes:

```bash
terraform output alb_dns_name      # -> http://<dns-name>/health once a real image has deployed
terraform output ecr_repository_url
terraform output codepipeline_name
```

The pipeline triggers automatically on the next push to the configured
branch (default `main`). You can also start it manually:

```bash
aws codepipeline start-pipeline-execution --name $(terraform output -raw codepipeline_name)
```

Watch it run:

```bash
aws codepipeline get-pipeline-state --name $(terraform output -raw codepipeline_name)
```

## 5. Cost notes for a student/free-tier AWS account

This stack is deliberately sized to be cheap:

- ECS Fargate task: 0.25 vCPU / 512 MB, 1 task (`ecs_task_cpu=256`,
  `ecs_task_memory=512`, `ecs_desired_count=1`) — a few dollars/month if
  left running continuously; **stop the ECS service (`desired_count=0`) or
  destroy the stack** when not actively demoing it.
- One NAT gateway (not one per AZ) — NAT gateways bill hourly plus data
  processing; this is the single largest recurring cost in this stack.
  Destroy the stack between sessions to avoid accruing NAT charges.
- ECR storage is billed per GB — the lifecycle policy caps retained image
  history so this stays small.
- CodeBuild `BUILD_GENERAL1_SMALL` is billed per build-minute; a full gated
  build (install + test + scans + docker build) typically runs in the
  10-20 minute range depending on scanner install time.
- CloudWatch Logs/alarms and Secrets Manager (one secret) are a few cents a
  month at this scale.
- No ACM certificate / Route 53 hosted zone is provisioned (the ALB uses
  plain HTTP on port 80), which avoids the cost and setup friction of a
  verified custom domain for a demo deployment.

## 6. `terraform destroy` cleanup

```bash
cd terraform/environments/dev
terraform destroy -var-file=terraform.tfvars
```

This tears down everything Terraform created, **except**:
- The S3 tfstate bucket and DynamoDB lock table (created manually in step
  3 — delete these yourself if you no longer need them:
  `aws s3 rb s3://<bucket> --force` and
  `aws dynamodb delete-table --table-name <table>`).
- The CodeStar Connection (created manually in step 2 — delete via the AWS
  Console if no longer needed).
- Any images left in ECR if `force_delete` were not set (this repo's
  `aws_ecr_repository` does not set `force_delete`, so `terraform destroy`
  will fail if images remain — delete images first with
  `aws ecr batch-delete-image` or add `force_delete = true` for a demo/dev
  environment where that tradeoff is acceptable).

## 7. Local development

```bash
cd app
cp ../.env.example .env   # edit JWT_SECRET etc. for local use
npm install
npm run dev                # starts on http://localhost:3000
curl http://localhost:3000/health
```

## 8. Testing

```bash
make install
make test           # unit + integration tests (app/tests + tests/integration)
make lint
```

## 9. Security testing

```bash
# Run whatever scanners are installed locally; each fails loudly (not
# silently) if its tool is missing, and the gate fails closed on that.
make security

# Test the gate's decision logic itself, against controlled fixtures,
# independent of whether any real scanner is installed:
make security-test
```

See `docs/troubleshooting.md` for exact install commands for each scanner
(Semgrep, Gitleaks, Checkov, Trivy, Syft) if you want every category to
actually run locally rather than reporting `tool_missing`.

## 10. Intentional-vulnerability demonstration

This walks through tripping each scanner on purpose, in an isolated and
clearly-marked way, showing the gate block the deployment, then reverting
to show it pass again. Every "vulnerable" snippet below lives only in your
local working tree during the demo — do not commit it.

### 10a. Trip the dependency scanner

```bash
cd app
npm install --no-save minimist@0.0.8   # a package with a long-published, well-known CVE
cd ..
bash security/scripts/run-dependency-scan.sh app
bash security/scripts/security-gate.sh   # expect: FAIL, dependencies category over threshold
```

Revert: `cd app && npm install && cd ..` (reinstalls from the clean
lockfile, removing the vulnerable extra package).

### 10b. Trip the secret scanner

```bash
mkdir -p demo && cat > demo/DELETE_ME_fake_secret.env <<'EOF'
# THIS IS A FAKE, CLEARLY-MARKED TEST VALUE — never a real credential.
AWS_SECRET_ACCESS_KEY=AKIAFAKEDEMOSECRETKEYXXXX
EOF
bash security/scripts/run-secret-scan.sh
bash security/scripts/security-gate.sh   # expect: FAIL, secrets category (zero tolerance)
```

Revert: `rm -rf demo/`

### 10c. Trip the SAST scanner

```bash
cat > app/src/DELETE_ME_insecure_demo.js <<'EOF'
// THIS FILE IS A DELIBERATE, ISOLATED DEMO OF AN INSECURE PATTERN.
// It is never imported by the app and must be deleted after the demo.
const { exec } = require('child_process');
function unsafeRun(userInput) {
  exec('echo ' + userInput); // command injection — flagged by Semgrep
}
module.exports = { unsafeRun };
EOF
bash security/scripts/run-sast.sh app/src
bash security/scripts/security-gate.sh   # expect: FAIL, SAST category over threshold
```

Revert: `rm app/src/DELETE_ME_insecure_demo.js`

### 10d. Trip the IaC scanner

```bash
cat >> terraform/modules/networking/main.tf <<'EOF'

# THIS RESOURCE IS A DELIBERATE, ISOLATED DEMO OF A MISCONFIGURATION.
# Delete it after the demo — an SSH port open to the world is never
# something this project actually ships.
resource "aws_security_group" "DELETE_ME_demo_open_sg" {
  name   = "delete-me-demo-open-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
EOF
bash security/scripts/run-iac-scan.sh terraform
bash security/scripts/security-gate.sh   # expect: FAIL, IaC category over threshold
```

Revert: remove the block you just appended (`git checkout --
terraform/modules/networking/main.tf`).

### 10e. Trip the container scanner

The most reliable way to demonstrate this without editing the Dockerfile
is to scan an intentionally old, unpatched public image instead of your
own build:

```bash
docker pull node:18.0.0-alpine   # old, has known CVEs by now
bash security/scripts/run-container-scan.sh node:18.0.0-alpine
bash security/scripts/security-gate.sh   # expect: FAIL, container category over threshold
```

Revert: nothing to revert — this never touched your own image; re-run
`bash security/scripts/run-container-scan.sh <your-real-image>` to restore
a clean container report before re-demoing the PASS case.

### 10f. Show the PASS case again

```bash
make security   # re-run every scanner against the clean tree
# expect: OVERALL RESULT: PASS
```

### 10g. Demonstrate fail-closed behavior directly (no scanner needed)

```bash
rm security/reports/secrets/secret-scan-report.json
bash security/scripts/security-gate.sh
# expect: FAIL — "report file missing ... (fail-closed)"

# restore it:
bash security/scripts/run-secret-scan.sh
```

This maps 1:1 to the automated version of the same checks in
`tests/security/run-tests.sh` (`make security-test`), which is what CI
actually runs on every change to `security/scripts/security-gate.sh` — the
manual walkthrough above is for a live demo audience, the automated one is
what keeps the gate correct over time.
