# Production Deployment: Incident Log

This document is a factual record of every real failure encountered while
deploying this project's Terraform-managed infrastructure and driving its
CodePipeline to a healthy, publicly reachable ECS Fargate service in a real
AWS account (`ap-south-1`). It exists for two reasons:

1. **Engineering honesty.** A project that claims to be "production-tested"
   should be able to show exactly what production disagreed with, not just
   a clean final `terraform apply` output.
2. **Research value.** Several of these incidents are not obvious from
   reading AWS's own documentation and were only found by going past it
   (CloudTrail event correlation, `docker inspect` on a base image, reading
   application logs against ALB vs. container-internal traffic). That
   process — not just the fix — is the reusable part.

Every root cause below was confirmed against real AWS API output before a
fix was written; none is inferred or assumed. Timestamps are from the
actual CodeBuild/ECS/CloudTrail logs produced during this deployment.

## Incident summary

| # | Symptom | Root cause | Layer | Found via |
|---|---|---|---|---|
| 1 | `terraform apply` failed: `InvalidParameterValue` on subnet AZs | Hardcoded `us-east-1a`/`us-east-1b` AZs don't exist in `ap-south-1` | Terraform/networking | Direct `apply` error output |
| 2 | 4 CloudWatch log groups failed to create: `AccessDeniedException` | KMS key policy granted the account root but not the `logs.<region>.amazonaws.com` service principal | Terraform/KMS | Direct `apply` error output |
| 3 | CodeBuild: `Not authorized to perform DescribeSecurityGroups` | CodeBuild's VPC mode needs explicit EC2 ENI-management IAM permissions; not implied by any other role | IAM | CodeBuild build log |
| 4 | CodeBuild: `YAML_FILE_ERROR` on a buildspec that parsed fine in GitHub Actions | AWS CodeBuild's buildspec YAML parser is stricter than GitHub Actions' — an unquoted `:` inside a plain scalar is read as a nested mapping key | CI config | CodeBuild `DOWNLOAD_SOURCE`/parse failure |
| 5 | CodeBuild: `yq: command not found` | `security-gate.sh` requires `yq`; GitHub Actions runners ship it, the CodeBuild managed image does not | CI config | CodeBuild build log |
| 6 | CodePipeline Deploy stage: generic `PermissionError`, 3 consecutive failures despite matching AWS's own documented reference IAM policy | CodePipeline's ECS deploy action also calls `ecs:TagResource` when registering a new task definition revision (it propagates the family's tags) — **not present in AWS's own published reference policy** | IAM | `aws cloudtrail lookup-events`, not the CodePipeline error message |
| 7 | ECS deployment circuit breaker tripped: `tasks failed to start` | ECS task definition's `image` referenced a real digest, but a later Terraform-only apply (fixing #8) re-registered the task definition using the module's own bootstrap default image tag (`:initial`), which was never pushed | Terraform/ECS | `aws ecs describe-services` events: `CannotPullContainerError` |
| 8 | ECS container marked `UNHEALTHY` and killed after ~7 minutes, despite the app answering the ALB's own health checks the entire time | The container-level `healthCheck` (both the Dockerfile's `HEALTHCHECK` and the ECS task definition's `healthCheck.command`) invoked a bare `"node"`. Exec-form `CMD`/`HEALTHCHECK` resolves `argv[0]` via `$PATH`, not through the image's `ENTRYPOINT` — and `gcr.io/distroless/nodejs22-debian12`'s `$PATH` does not include `/nodejs/bin`, even though its `ENTRYPOINT` is `["/nodejs/bin/node"]` | Container image | Application logs showed **zero** requests from the internal health-check process (only from `ELB-HealthChecker/2.0`); confirmed root cause via `docker inspect --format '{{json .Config.Entrypoint}}'` / `'{{json .Config.Env}}'` |

## Incident 8 in detail — the most instructive one

This is worth walking through because the failure signature is misleading
by default, and the fix requires evidence a log line will never show you
directly.

**Symptom.** `aws ecs describe-services` reported the deployment's
`rolloutState` as `FAILED` with reason `"ECS deployment circuit breaker:
tasks failed to start"`, and the ECS service event log showed:

```
(service ...) (task ...) failed container health checks.
(service ...) has stopped 1 running tasks: (task ...).
```

**The misleading part.** The ALB's own external health check
(`ELB-HealthChecker/2.0`) was hitting `/health` on the task's private IP
every 15 seconds and getting `200 OK` the entire time — for over 7
minutes, right up until the task was killed. If you only looked at the
ALB target group's health state, or `curl`'d the load balancer yourself,
the service looked completely healthy.

**The actual investigation.** Pulling the task's CloudWatch log stream
directly (`aws logs get-log-events`) and grepping every `/health` request
by its `user-agent` showed that **100% of them were `ELB-HealthChecker/2.0`**
— not one request in the log ever came from the container's own internal
health-check process (which, if it were reaching the app at all, would
show up as a plain Node.js `http.get()` client with no special user agent).
That absence is the actual signal: ECS's container-level `healthCheck`
was never reaching the application process at all.

**Root cause.** The image is `gcr.io/distroless/nodejs22-debian12:nonroot`.
Verified directly:

```
$ docker inspect gcr.io/distroless/nodejs22-debian12:nonroot --format '{{json .Config.Entrypoint}}'
["/nodejs/bin/node"]
$ docker inspect gcr.io/distroless/nodejs22-debian12:nonroot --format '{{json .Config.Env}}'
["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"]
```

The image's own `ENTRYPOINT` is the absolute path to `node`, so the
container's *main process* starts fine — `ENTRYPOINT` doesn't need a
`$PATH` lookup. But `HEALTHCHECK`/ECS's `healthCheck.command` is an
independent `exec()` that Docker/ECS resolves via `$PATH` lookup exactly
like a shell would, and this image's `$PATH` is the standard system
directories only — it does not include `/nodejs/bin`. Every single health
check invocation failed with (effectively) "executable file not found in
$PATH" before it ever made a TCP connection, which is exactly consistent
with the log evidence: zero internal health-check requests, ever, for the
whole task lifetime.

**Fix.** Use the absolute path in both places:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["/nodejs/bin/node", "-e", "..."]
```

```hcl
healthCheck = {
  command = ["CMD", "/nodejs/bin/node", "-e", "..."]
  ...
}
```

**Why this generalizes.** Any distroless (or otherwise shell-less,
minimal-`$PATH`) base image will hit this exact failure mode for *any*
exec-form health check that assumes the entrypoint binary is on `$PATH` —
it is a property of how Docker/ECS execute `CMD`-form health checks, not
something specific to Node.js or to this one image. The general lesson:
an exec-form health check must use the same absolute path as the image's
own `ENTRYPOINT`, verified with `docker inspect`, never assumed.

## Incident 6 in detail — trusting a vendor's own documented policy less than CloudTrail

AWS publishes a documented "reference" IAM policy for CodePipeline's ECS
deploy action. Two consecutive attempts matched it exactly — once with a
narrowly scoped custom policy, once by copying AWS's own reference policy
verbatim — and both still failed with the same generic
`"not sufficient permissions to access ECS"` message, which CodePipeline
does not expand with the specific denied action.

`aws cloudtrail lookup-events` (filtering for `AccessDenied` around the
failed execution's timestamp) surfaced the actual denial:

```
User: arn:aws:sts::<account>:assumed-role/<name>-codepipeline-role/<session>
is not authorized to perform: ecs:TagResource
on resource: arn:aws:ecs:<region>:<account>:task-definition/<name>-app:*
because no identity-based policy allows the ecs:TagResource action
```

CodePipeline's ECS deploy action propagates the task definition family's
tags onto every new revision it registers — an implementation detail not
present in AWS's own published reference policy for this feature. The fix
was a single scoped statement granting `ecs:TagResource` on the task
definition family ARN. **Lesson:** for an opaque IAM `AccessDenied`
without a specific action named in the error, CloudTrail's raw event log
is more reliable than a cloud provider's own "complete" reference policy.

## What this demonstrates for the project's threat/reliability model

None of these eight incidents were security vulnerabilities in the
conventional sense (no injected malicious code, no exploited
misconfiguration) — they were the kind of operational correctness bugs
that a first real deployment to a fresh AWS account reliably surfaces:
region-specific assumptions, implicit IAM permission requirements a cloud
provider's own documentation omits, and a health-check assumption that
silently breaks under a specific (increasingly common, security-motivated)
container-image choice. Finding and fixing all eight before the service
was billed as "working" is itself evidence for this project's broader
thesis (see [`research-notes.md`](research-notes.md)): verification has to
be real and adversarial against actual system behavior, not just "the
`terraform apply` command exited 0."
