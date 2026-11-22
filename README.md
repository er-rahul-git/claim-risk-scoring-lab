# claim-risk-scoring-lab

A working practice project for an event-driven **Claim Risk Scoring** flow, built the way enterprise teams build it:
code **and** Terraform in GitHub, layered configs, Docker on EC2, S3 as the event backbone,
and everything deployed by pipelines. Synthetic data only; no real claims data or account IDs live here.

```
UI ─▶ S3 requests/ ─▶ trigger Lambda ─▶ Risk Scoring API (EC2, Docker) ─┬─ Provider ┐
                                           replies 202, works in background   ├─ CMS      ├─▶ S3 responses/
                                                                              └─ Payer    ┘
                                           Composite score ─▶ S3 output/ ─▶ notifier Lambda ─▶ WebSocket ─▶ UI
```

| Read next | For |
| --- | --- |
| [OVERVIEW_AND_LOCAL_RUN.md](OVERVIEW_AND_LOCAL_RUN.md) | Run it on your laptop in 5 minutes, then deploy to AWS step by step |
| [HIGH_LEVEL_ARCHITECTURE.md](HIGH_LEVEL_ARCHITECTURE.md) | Components, decisions, IAM, what maps to which agreed step |
| [docs/ENV_SETUP.md](docs/ENV_SETUP.md) | Template for the setup document (acceptance criterion 4) |

## Repository layout

```
.github/            PR template, workflow-config.yml, workflows: ci.yml infra.yml deploy.yml
configs/            base_config.yaml + environments/{local,nonprod,prod}.yaml (env wins on conflicts)
audit_api/          FastAPI app, orchestrator, storage abstraction, JSON schemas, scripts/
lambdas/            trigger/ notifier/ ws/ presign/   (one handler.py each, stdlib + boto3 only)
infra/terraform/    bootstrap/ (run once)  modules/ (network storage iam api_ec2 lambda_trigger notifier_ws observability)
                    envs/nonprod  envs/prod   (identical main.tf, different terraform.tfvars + backend.hcl)
tests/              unit/ (pytest, runs in CI)  smoke/smoke_test.py (against a real environment)
samples/            valid and invalid synthetic requests
scripts/            local_demo.py
Dockerfile.devops   multi-stage, build secrets, non-root  (enterprise pattern)
```

## Quick start

```bash
make venv && source .venv/bin/activate
make test          # 19 unit tests, coverage gate 80%
make run           # terminal 1: API on :8080, a local folder plays the S3 bucket
make demo          # terminal 2: request -> real trigger handler -> API -> 3 scripts -> composite -> output
make demo-invalid  # invalid request -> status INVALID, no script runs
```

## Status of each piece

| Piece | Verified here | Verify yourself |
| --- | --- | --- |
| API, orchestrator, scripts, schemas | unit tests + local end-to-end demo | - |
| Lambdas (trigger, ws, notifier) | unit tests (moto for S3/DynamoDB) | in AWS via smoke test |
| Terraform | HCL parses; module inputs/outputs/tfvars cross-checked | `terraform init -backend=false && terraform validate`, then plan |
| Dockerfile | - | `make docker && make docker-run` (CI also builds it) |
| Workflows | YAML parses | first PR on GitHub |
