SHELL := /bin/bash
APP_ENV ?= local
ENV ?= nonprod
TF := terraform -chdir=infra/terraform/envs/$(ENV)

.PHONY: help
help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

venv: ## create .venv with dev dependencies
	python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt

test: ## unit tests + coverage gate
	python -m pytest

lint: ## ruff + terraform fmt check
	ruff check .
	terraform fmt -check -recursive infra/terraform || true

run: ## run the API locally (folder .localbucket/ plays S3)
	APP_ENV=$(APP_ENV) uvicorn audit_api.app:app --port 8080 --reload

demo: ## send the sample request through the real trigger handler (needs `make run`)
	python scripts/local_demo.py

demo-invalid: ## same with an invalid request (expect status INVALID, no script files)
	python scripts/local_demo.py --sample invalid_request.json

docker: ## build the API image
	docker build -f Dockerfile.devops --build-arg GIT_SHA=$$(git rev-parse --short HEAD 2>/dev/null || echo dev) -t crs-audit-api:local .

docker-run: ## run the image locally
	docker run --rm -p 8080:8080 -e APP_ENV=local -v $$PWD/.localbucket:/app/.localbucket crs-audit-api:local

tf-init: ## terraform init (ENV=nonprod|prod)
	$(TF) init -backend-config=backend.hcl

tf-plan: ## terraform plan
	$(TF) plan -out=tfplan

tf-apply: ## apply the saved plan
	$(TF) apply tfplan

tf-destroy: ## tear down (end of every practice day)
	$(TF) destroy

smoke: ## smoke test against a real environment (ENV=nonprod)
	python tests/smoke/smoke_test.py --env $(ENV)
