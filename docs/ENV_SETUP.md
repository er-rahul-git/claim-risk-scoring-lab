# Environment setup record (acceptance criteria 1, 3, 4)

Fill this in as you go. It is the document another engineer uses to reproduce the setup.

## 1. Confirmed environment

| Item | nonprod | prod | Confirmed by / date |
| --- | --- | --- | --- |
| AWS account (alias) | | | |
| Region | ap-south-1 | ap-south-1 | |
| VPC / egress mode | | | |
| GitHub repo / environments | | | |
| State bucket | | | |
| Alarm recipients | | | |

## 2. Access

| Who | How | Permission set / role |
| --- | --- | --- |
| Engineers | Identity Center portal | AdministratorAccess (nonprod), ReadOnlyAccess (prod) |
| GitHub Actions | OIDC | crs-github-terraform-<env>, crs-github-deploy-<env> |

## 3. Configuration values

| Key | nonprod | prod | Set in |
| --- | --- | --- | --- |
| storage.bucket | crs-nonprod-data-<acct> | crs-prod-data-<acct> | EC2 user data (`APP__storage__bucket`) |
| scripts.timeout_seconds | 30 | 60 | configs/environments |
| observability.arize.enabled | false | false | configs/environments |

## 4. Smoke test results

| Date | Env | Image SHA | Result | Notes |
| --- | --- | --- | --- | --- |
| | | | | |

## 5. Failures and resolutions

| Date | Symptom | Root cause | Fix |
| --- | --- | --- | --- |
| | | | |
