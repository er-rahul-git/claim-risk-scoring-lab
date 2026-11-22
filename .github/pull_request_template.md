## What and why
<!-- One or two lines. Link the user story. -->

## Type
- [ ] App code (API / scripts / Lambdas)
- [ ] Infra (Terraform)
- [ ] Pipeline / config
- [ ] Docs

## Checklist
- [ ] `make test` passes (coverage gate 80%)
- [ ] `ruff check .` clean; `terraform fmt -recursive` run if infra changed
- [ ] Shared settings in `configs/base_config.yaml`, env-specific ones in `configs/environments/*.yaml`
- [ ] No secrets, account IDs, keys or real claim data in code, config or samples
- [ ] Infra change: Terraform plan comment reviewed; IAM changes are least privilege
- [ ] Docs updated (README / HIGH_LEVEL_ARCHITECTURE.md / OVERVIEW_AND_LOCAL_RUN.md)

## Evidence
<!-- plan summary, smoke-test output, screenshots -->
