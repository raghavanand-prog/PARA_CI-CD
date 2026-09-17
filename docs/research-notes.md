# Research Notes

This document frames the engineering work in this repository as a research
artifact: a concrete system built specifically to make the research
questions below *answerable by measurement*, rather than a report of
results that have not actually been measured. Nothing in this file states
or implies a measured outcome — every number that would appear here has to
come from running the methodology below against real pipeline executions,
which this repository is built to support but does not itself claim to
have done.

## Problem Statement

Security scanning is frequently bolted onto CI/CD pipelines as an
advisory, non-blocking step: a report gets generated, a dashboard gets a
new red badge, and the deployment proceeds regardless. This decouples
*detection* from *prevention* — the scan can be perfectly accurate and
still have zero effect on what actually ships, because nothing in the
pipeline's control flow depends on its result. Practitioner reports and
industry surveys widely describe this gap (security tooling adopted, but
not enforced), but the specific, mechanical question of *how* to make
enforcement actually automated, fail-closed, and resistant to silent
bypass — as opposed to "add a manual approval step and hope someone reads
the report before clicking approve" — is less commonly treated as a
first-class engineering problem with its own design and testable
correctness properties.

This project treats "the gate" as a piece of software with its own
specification (a fail-closed policy engine, `security/scripts/
security-gate.sh`, evaluated against `security/policy/security-policy.yaml`)
and its own test suite (`tests/security/run-tests.sh`), rather than as
pipeline glue that happens to call some scanners.

## Research Questions

- **RQ1.** Does moving the security gate from an advisory/manual step to
  an automated, fail-closed policy engine measurably change the rate at
  which vulnerable code reaches a deployable state, compared to the same
  pipeline with the gate present but non-blocking (report-only)?
- **RQ2.** What is the actual time and false-positive cost of running a
  five-category scan suite (SAST, SCA, secrets, IaC, container) on every
  build, and is that cost proportionate to the vulnerabilities it catches
  relative to catching them later (e.g. in production incident response)?
- **RQ3.** Does a fail-closed gate design (missing/malformed/crashed
  scanner = blocked, not skipped) measurably reduce the number of
  deployments that proceed despite incomplete security evidence, compared
  to a fail-open design, without an unacceptable increase in
  false-positive-driven pipeline failures?

## Hypotheses

- **H1.** An automated, fail-closed security gate integrated into the
  Build stage of a CI/CD pipeline blocks a materially higher proportion of
  commits containing an injected CRITICAL/HIGH-severity vulnerability than
  a pipeline where the same scans run but are advisory-only (no blocking
  behavior). *Rationale:* an advisory-only gate's effect on the deployment
  decision is mediated entirely by whether a human reads and acts on the
  report; an automated gate removes that mediation.
- **H2.** The added wall-clock time of running all five scanner categories
  in the Build stage is small relative to total pipeline execution time
  (dominated by dependency install and Docker build), such that the
  security gate does not become the primary bottleneck perceived by
  developers. *Rationale:* SAST/secrets/IaC scans on a small codebase are
  typically sub-minute; container scanning against a small Alpine-based
  image is the most likely outlier.
- **H3.** A fail-closed gate design blocks 100% of the "scanner didn't
  actually run" cases (missing report, malformed report, tool crash) that
  a fail-open design would silently pass, at the cost of some number of
  false-positive pipeline failures caused by transient scanner
  installation/network issues rather than real findings. *Rationale:* this
  is a direct, mechanical consequence of the fail-closed design in
  `security-gate.sh` and is the one hypothesis in this list that is
  already verified as a *logical* property (see "What This Repository
  Already Demonstrates" below) — H3 as stated is about the *operational*
  cost/frequency of that behavior over real pipeline runs, which is a
  distinct, unmeasured empirical question from its logical correctness.

**These are hypotheses to be tested, not findings.** No claim is made here
about which of H1-H3 the data would actually support; only their
methodology and metrics are defined below.

## What This Repository Already Demonstrates (logical correctness, not measured outcomes)

`tests/security/run-tests.sh` verifies, as a matter of code correctness,
that the gate:
1. Passes when all five categories are within policy.
2. Fails when a severity threshold is exceeded.
3. Fails on any secret finding (zero-tolerance category).
4. Fails closed when a report is missing.
5. Fails closed when a report is malformed (not valid JSON).
6. Fails closed when a scanner's status indicates it crashed.
7. Fails closed when a scanner's status indicates it never ran
   (tool not installed).

This establishes that the *mechanism* behaves as designed. It does not,
by itself, establish H1-H3, which are claims about behavior across many
real pipeline executions over time — the methodology below is what would
be needed to move from "the gate is built correctly" to "the gate changes
outcomes in the way we hypothesized."

## Methodology

### Experimental setup
- Two pipeline configurations sharing identical scan tooling and policy
  thresholds:
  - **Gated**: `security-gate.sh` enforced (current implementation).
  - **Advisory**: identical scans run, reports generated, but the Build
    stage does not fail on gate result (a one-line change: drop the exit
    code from `security-gate.sh` before it propagates).
- A corpus of commits, some clean and some containing a deliberately
  injected vulnerability from each category (mirroring the demo scenarios
  in `docs/deployment.md` section 10: a known-CVE dependency, a fake
  test-only secret, an unsafe code pattern, a misconfigured Terraform
  resource, an outdated base image).
- Both configurations run against the same corpus, repeated across enough
  runs to characterize variance (scan tool network calls, transient
  installation flakiness).

### Metrics

| Metric | Definition | Answers |
|---|---|---|
| **Deployment Block Rate (DBR)** | % of commits containing an injected vulnerability that were prevented from reaching the Deploy stage | RQ1 / H1 |
| **Vulnerability Detection Rate (VDR)** | % of injected vulnerabilities that at least one scanner correctly flagged (regardless of whether the gate blocked the build) | RQ1 (isolates detection from enforcement) |
| **False Positive Rate (FPR)** | % of clean commits (no injected vulnerability) that the gate blocked anyway | RQ2 / RQ3 |
| **Mean Time To Detect (MTTD)** | Wall-clock time from commit push to the first scan report flagging the injected issue | RQ2 |
| **Mean Time To Remediate/Respond (MTTR)** | Wall-clock time from a gate FAILURE being visible to a corrected commit passing the gate, in a controlled remediation exercise | RQ2 |
| **Scan Overhead** | Wall-clock time added to total pipeline duration by running all five scan categories, isolated from install/build/test time | H2 |
| **Pipeline Execution Time** | Total wall-clock time from Source trigger to Deploy stage completion (or to Build stage failure, for blocked runs) | H2 |
| **Fail-Closed Trigger Rate** | % of runs where the gate failed specifically due to a missing/malformed/crashed report rather than a genuine policy threshold violation | H3 |

### Analysis plan
- DBR and VDR are compared between Gated and Advisory configurations
  (H1): a meaningfully higher DBR under Gated, with comparable VDR (since
  both configurations run identical scans), would support H1 — the
  detection capability is held constant, isolating the effect of
  enforcement.
- Scan Overhead and Pipeline Execution Time are reported as distributions
  (not single numbers) across repeated runs, given expected variance from
  network-dependent steps (scanner installation, dependency resolution)
  (H2).
- Fail-Closed Trigger Rate is tracked separately from genuine policy
  violations specifically so that H3's cost side (operational friction
  from transient failures) is not conflated with its benefit side
  (catching real incomplete-evidence cases) (H3).

## Explicitly Not Claimed

- No specific DBR, VDR, FPR, MTTD, MTTR, or timing figure is stated
  anywhere in this repository as a measured result. Any such number would
  need to come from actually executing the methodology above against real
  pipeline runs in a real AWS account — which is exactly the deployment
  this repository is built to support (see `docs/deployment.md`), not
  something to be asserted in advance.
- The hypotheses above are reasoned expectations based on the gate's
  design, not conclusions. A rigorous write-up of this work would report
  whichever of H1-H3 the actual data supports or contradicts, including
  the possibility that none of them hold as stated.
