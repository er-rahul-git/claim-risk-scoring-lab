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
ui/                 index.html (single page, no build step), config.example.js
local_stack/        laptop stand-ins for S3 events, presign, WebSocket API (the API itself runs for real)
infra/terraform/    bootstrap/ (run once)  modules/ (network storage iam api_ec2 lambda_trigger notifier_ws presign observability)
                    envs/nonprod  envs/prod   (identical main.tf, different terraform.tfvars + backend.hcl)
tests/              unit/ (pytest, runs in CI)  smoke/smoke_test.py (against a real environment)
samples/            valid and invalid synthetic requests
scripts/            local_demo.py
Dockerfile.devops   multi-stage, build secrets, non-root  (enterprise pattern)
```

## Quick start

```bash
make venv && source .venv/bin/activate
make test          # 23 unit tests, coverage gate 80%
make dev           # UI + API + local AWS stand-ins, then open http://localhost:8000
```

In the browser, click **Run Audit**. The page subscribes on a WebSocket, gets an upload URL, PUTs the
request JSON into `requests/`, and the result is pushed back in under a second. **Try an invalid request**
shows the schema errors (no script runs). Every hop is printed as a JSON log line in the terminal.

Without the UI: `make run` (terminal 1) and `make demo` / `make demo-invalid` (terminal 2).

## Status of each piece

| Piece | Verified here | Verify yourself |
| --- | --- | --- |
| API, orchestrator, scripts, schemas | unit tests + local end-to-end demo | - |
| UI + local stack | unit tests + headless-browser run (valid and invalid request) | `make dev` |
| Lambdas (trigger, ws, notifier) | unit tests (moto for S3/DynamoDB) | in AWS via smoke test |
| Terraform | HCL parses; module inputs/outputs/tfvars cross-checked | `terraform init -backend=false && terraform validate`, then plan |
| Dockerfile | - | `make docker && make docker-run` (CI also builds it) |
| Workflows | YAML parses | first PR on GitHub |


## test ci/cd