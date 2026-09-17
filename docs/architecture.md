# Architecture

## 1. High-level system

```mermaid
flowchart LR
    Dev[Developer] -->|git push| GH[(GitHub Repository)]
    GH -->|webhook via CodeStar Connection| CP[AWS CodePipeline]

    subgraph AWS["AWS Account"]
        CP --> CB[AWS CodeBuild]
        CB -->|scan reports + gate decision| Gate{{Security Gate}}
        Gate -->|PASS| ECR[(Amazon ECR)]
        Gate -->|FAIL| Stop[["Pipeline stops.\nECS never touched."]]
        ECR --> ECS[ECS Fargate Service]
        ALB[Application Load Balancer] --> ECS
        ECS --> CW[CloudWatch Logs & Alarms]
        CB --> CW
        CP --> CW
        SM[Secrets Manager / SSM] -.->|resolved at container startup| ECS
        KMS[KMS CMK] -.->|encrypts| ECR
        KMS -.->|encrypts| SM
        KMS -.->|encrypts| CW
    end

    User[End User] -->|HTTPS| ALB
```

Everything downstream of the Security Gate only runs if the gate passes.
There is no manual approval action in CodePipeline — the gate itself,
running as CodeBuild commands, is the enforcement point.

## 2. CI/CD pipeline flow

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub
    participant CP as CodePipeline
    participant CB as CodeBuild
    participant ECR as ECR
    participant ECS as ECS Fargate

    Dev->>GH: git push (main)
    GH->>CP: Source stage triggers (CodeStar Connection)
    CP->>CB: Build stage starts (ci/buildspec.yml)
    CB->>CB: install deps, lint, unit tests
    CB->>CB: docker build
    CB->>CB: run SAST / SCA / secrets / IaC / container scans
    CB->>CB: security-gate.sh evaluates all reports vs. policy
    alt Gate PASS
        CB->>ECR: docker push (digest-pinned)
        CB->>CP: Build stage SUCCEEDED, imagedefinitions.json
        CP->>ECS: Deploy stage — update service to new image
        ECS-->>Dev: New revision running behind ALB
    else Gate FAIL
        CB->>CP: Build stage FAILED (non-zero exit)
        CP-->>Dev: Pipeline stops — Deploy stage never runs
    end
```

## 3. Security gate decision flow

```mermaid
flowchart TD
    Start([security-gate.sh starts]) --> LoadPolicy[Load security-policy.yaml]
    LoadPolicy -->|invalid YAML / missing sections| AbortHard[["exit 3\nGate cannot run"]]
    LoadPolicy -->|valid| ForEach[For each category:\nSAST, Deps, Secrets, IaC, Container]

    ForEach --> CheckReport{Report file exists,\nis valid JSON,\nstatus == completed?}
    CheckReport -->|No| FailClosed[["Category = FAIL\n(fail-closed)"]]
    CheckReport -->|Yes| CheckThreshold{Findings within\npolicy thresholds?}
    CheckThreshold -->|No| FailViolation[["Category = FAIL\n(threshold violated)"]]
    CheckThreshold -->|Yes| Pass[["Category = PASS"]]

    FailClosed --> Aggregate
    FailViolation --> Aggregate
    Pass --> Aggregate[Aggregate all category results]

    Aggregate --> AnyFail{Any category FAIL?}
    AnyFail -->|Yes| Overall[["OVERALL RESULT: FAIL\nexit 1 — deployment blocked"]]
    AnyFail -->|No| OverallPass[["OVERALL RESULT: PASS\nexit 0 — deployment proceeds"]]
```

## 4. AWS infrastructure

```mermaid
flowchart TB
    subgraph VPC["VPC (10.20.0.0/16)"]
        subgraph PublicAZ1["Public Subnet AZ-1"]
            ALB1[ALB]
            NAT[NAT Gateway]
        end
        subgraph PublicAZ2["Public Subnet AZ-2"]
            ALB2[ALB]
        end
        subgraph PrivateAZ1["Private Subnet AZ-1"]
            Task1[ECS Fargate Task]
        end
        subgraph PrivateAZ2["Private Subnet AZ-2"]
            Task2[ECS Fargate Task]
        end
        IGW[Internet Gateway]
    end

    Internet((Internet)) --> IGW --> ALB1 & ALB2
    ALB1 & ALB2 --> Task1 & Task2
    Task1 & Task2 -.->|outbound only, via NAT| NAT --> IGW

    Task1 & Task2 -.->|pull image| ECR[(ECR)]
    Task1 & Task2 -.->|resolve secrets| SM[(Secrets Manager / SSM)]
    Task1 & Task2 -.->|logs| CW[(CloudWatch Logs)]
```

Key properties:
- ECS tasks run in **private subnets only**, with no public IP. The ALB in
  the public subnets is the sole ingress path.
- The ECS tasks' security group accepts inbound traffic **only** from the
  ALB's security group, on the container port.
- Outbound internet access from private subnets (image pulls that aren't
  cached, dependency downloads during build-time only, AWS API calls) goes
  through a NAT gateway — there is no direct route from a private subnet to
  the internet gateway.

## 5. Threat / data-flow diagram

```mermaid
flowchart LR
    subgraph Untrusted
        Attacker[Attacker]
        PublicInternet[Public Internet]
    end

    subgraph TrustBoundary1["Trust boundary: internet -> ALB"]
        ALB[ALB]
    end

    subgraph TrustBoundary2["Trust boundary: ALB -> private subnet"]
        ECS[ECS Task]
    end

    subgraph TrustBoundary3["Trust boundary: CI/CD -> AWS account"]
        GH[GitHub source]
        CB[CodeBuild]
        Gate{{Security Gate}}
    end

    Attacker -->|1. HTTP requests| PublicInternet --> ALB
    ALB -->|2. forwarded, TLS terminated| ECS
    ECS -->|3. reads secret at startup| SM[(Secrets Manager)]

    GH -->|4. source code, untrusted until scanned| CB
    CB -->|5. scans + gate decision| Gate
    Gate -->|6. PASS only| ECR[(ECR)]
    ECR -->|7. pulled by ECS agent, IAM-scoped| ECS

    style TrustBoundary1 stroke-dasharray: 4 4
    style TrustBoundary2 stroke-dasharray: 4 4
    style TrustBoundary3 stroke-dasharray: 4 4
```

Numbered flows map directly to the STRIDE analysis in
[`threat-model.md`](./threat-model.md): (1)/(2) cover ALB/app-layer threats
(rate limiting, input validation, injected headers), (3) covers secrets
handling, (4)-(6) cover supply-chain/pipeline-integrity threats (why the
gate exists at all), and (7) covers image-pull/registry integrity
(immutable tags, scan-on-push, least-privilege IAM).

## Component responsibilities

| Component | Responsibility |
|---|---|
| GitHub | Source of truth for application code, IaC, pipeline config |
| CodeStar Connection | Authenticated, tokenless link from CodePipeline to GitHub |
| CodePipeline | Orchestrates Source -> Build -> Deploy, no manual gates |
| CodeBuild | Runs `ci/buildspec.yml`: build, test, scan, gate, push |
| `security-gate.sh` | Policy engine — the actual pass/fail decision maker |
| ECR | Immutable, scan-on-push image registry |
| ECS Fargate | Runs the container, no server management |
| ALB | TLS termination point (in a real deployment) and load balancing |
| Secrets Manager / SSM | Runtime secret/config injection, never baked into the image |
| CloudWatch | Logs, metrics, alarms, SNS notifications |
| KMS | Encryption at rest for ECR, Secrets Manager, CloudWatch Logs, S3 |
