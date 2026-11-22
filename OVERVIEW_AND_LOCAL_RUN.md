# Overview and local run

## What the system does

A user asks for a risk score for a claim. The request travels as **files in S3**:
the UI writes `requests/<id>.json`, an S3 event starts the trigger Lambda, which passes only the **S3 path**
to the Risk Scoring API. The API validates the request, runs the Provider, CMS and Payer scripts in parallel
(each writes `responses/<script>/<id>.json`), combines them with the Composite script and writes
`output/<id>.json`. An S3 event on `output/` makes the notifier push the result to the UI over a WebSocket.

## 1. Run locally (no AWS)

```bash
make venv && source .venv/bin/activate     # Python 3.11+
make test                                  # unit tests + coverage
make run                                   # terminal 1
make demo                                  # terminal 2
```

`APP_ENV=local` switches storage to the folder `.localbucket/`; everything else is the same code that runs in AWS.
Inspect the files the flow produced:

```bash
find .localbucket -name 'demo-001.json'
cat .localbucket/output/demo-001.json
```

Override any setting without editing files: `APP__scripts__timeout_seconds=5 make run`.

Docker:

```bash
make docker && make docker-run      # then `make demo` in another terminal
```

## 2. Deploy to your practice AWS accounts

Prerequisites: AWS Organizations with `alnonprod` / `alprod` accounts, Identity Center profiles
(`aws configure sso`), Terraform >= 1.10, a GitHub repo (see Phase 1b in the practice plan).

### 2.1 Bootstrap once per account (from your laptop)

```bash
cd infra/terraform/bootstrap
aws sso login --profile crs-nonprod
AWS_PROFILE=crs-nonprod terraform init
AWS_PROFILE=crs-nonprod terraform apply -var env=nonprod -var github_repo=<you>/claim-risk-scoring-lab \
  -var 'deploy_trusted_environments=["prod"]'
# note the outputs: state_bucket, terraform_role_arn, deploy_role_arn
```

Repeat with `crs-prod` / `env=prod` (without `deploy_trusted_environments`).

### 2.2 Wire GitHub

1. Repo **Settings → Environments**: create `nonprod` and `prod`; on `prod` add yourself as required reviewer.
2. In each environment add **variables**: `AWS_TERRAFORM_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`
   (from the bootstrap outputs of that account). In `prod` also add `AWS_NONPROD_DEPLOY_ROLE_ARN`.
3. Put the state bucket names into `infra/terraform/envs/*/backend.hcl` and your repo name into `terraform.tfvars`.
4. Protect `main`: require PR + passing `ci` checks.

### 2.3 Create the infrastructure (through a PR)

Open a PR that changes `infra/` (for example, set `alarm_email`). The `infra` workflow posts the plan as a comment.
Merge it: nonprod is applied. Then **Actions → infra → Run workflow → prod** and approve.

### 2.4 Deploy the API

Merging app code to `main` runs `deploy.yml`: build the image, push `crs-nonprod-api:<sha>`, write the SHA to
SSM `/crs-nonprod/api/image_tag`, roll the Auto Scaling group, run the smoke test.
Prod: **Actions → deploy → Run workflow → prod**, give the SHA that passed in nonprod. The same image is copied.

### 2.5 Smoke test by hand

```bash
aws sso login --profile crs-nonprod
AWS_PROFILE=crs-nonprod python tests/smoke/smoke_test.py --env nonprod \
  --account <nonprod-account-id> --ws "$(terraform -chdir=infra/terraform/envs/nonprod output -raw websocket_url)"
```

### 2.6 Tear down at the end of the day

```bash
make tf-destroy ENV=nonprod     # or run the destroy from a PR-less manual workflow if you add one
```

## Cost notes (practice)

| Item | Roughly | Note |
| --- | --- | --- |
| NAT gateway (nonprod, `egress_mode = "nat"`) | hourly charge + data | cheapest way to give EC2 package/registry access |
| Interface endpoints (prod, `egress_mode = "endpoints"`) | hourly charge per endpoint per AZ | 8 endpoints x 2 AZs costs more than one NAT; it buys "no internet path" |
| Internal ALB | hourly charge | needed for a stable API address |
| EC2 t3.small / t3.medium | hourly | 1 instance nonprod, 2 prod |
| Lambda, S3, DynamoDB, API Gateway | near zero at practice volume | |

Destroy every evening. The budget alert in the management account covers all accounts.
