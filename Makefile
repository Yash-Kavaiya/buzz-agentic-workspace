# Thin wrappers over ./scripts/buzzctl and ./tests/run_all.sh.
#
# `make` is muscle memory for a lot of people, and `make help` is a faster way
# to find a command than reading a CLI's usage text. Nothing here does work of
# its own — buzzctl is the tool.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

BUZZCTL := ./scripts/buzzctl
ENV ?= dev

.PHONY: help
help: ## Show this help
	@echo "buzz-agentic-workspace"
	@echo
	@echo "Usage: make <target> [ENV=dev|staging|prod]"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "ENV is currently: $(ENV)"
	@echo "Everything else: $(BUZZCTL) help"

# ── Checks ───────────────────────────────────────────────────────────────────

.PHONY: check
check: ## Run every check that needs no cloud account
	@./tests/run_all.sh

.PHONY: fmt
fmt: ## Format Terraform in place
	@terraform fmt -recursive terraform/

.PHONY: render
render: ## Render the chart for ENV into rendered/ (needs helm)
	@mkdir -p rendered
	@./scripts/lib/fetch-chart-deps.sh >/dev/null
	@helm template buzz helm/buzz-gke --namespace buzz \
		--values helm/buzz-gke/values.yaml \
		--values helm/buzz-gke/values-$(ENV).yaml \
		--values .github/ci-values.yaml \
		> rendered/$(ENV).yaml
	@echo "rendered/$(ENV).yaml"

.PHONY: policy
policy: render ## Check rendered manifests against policy/ (needs conftest)
	@conftest test --policy policy/conftest rendered/$(ENV).yaml

# ── Platform ─────────────────────────────────────────────────────────────────

.PHONY: plan
plan: ## terraform plan for ENV
	@$(BUZZCTL) infra plan $(ENV)

.PHONY: apply
apply: ## terraform apply for ENV
	@$(BUZZCTL) infra apply $(ENV)

.PHONY: secrets
secrets: ## Generate and store any missing secrets for ENV
	@$(BUZZCTL) secrets init $(ENV)

.PHONY: mirror
mirror: ## Mirror and pin the Buzz image for ENV
	@$(BUZZCTL) images mirror $(ENV)

.PHONY: preflight
preflight: ## Preflight ENV, including the object-store conformance gate
	@$(BUZZCTL) preflight $(ENV)

.PHONY: deploy
deploy: ## Deploy to ENV
	@$(BUZZCTL) deploy $(ENV)

.PHONY: verify
verify: ## Verify a running ENV end to end
	@$(BUZZCTL) verify $(ENV)

.PHONY: up
up: apply secrets mirror preflight deploy verify ## Everything, in order, for ENV

# ── Day two ──────────────────────────────────────────────────────────────────

.PHONY: status
status: ## Show workloads, gateway and certificates for ENV
	@$(BUZZCTL) status $(ENV)

.PHONY: logs
logs: ## Tail the relay log for ENV
	@$(BUZZCTL) logs $(ENV) -f

.PHONY: doctor
doctor: ## Diagnose an unhealthy ENV
	@$(BUZZCTL) doctor $(ENV)

.PHONY: members
members: ## List the relay roster for ENV
	@$(BUZZCTL) members $(ENV)

.PHONY: keygen
keygen: ## Mint a Nostr keypair
	@$(BUZZCTL) keygen

.PHONY: clean
clean: ## Remove local render output and cached platform state
	@rm -rf rendered/ helm/buzz-gke/charts helm/buzz-gke/Chart.lock
	@echo "removed rendered output and fetched chart dependencies"
	@echo "note: .buzzctl/ holds cached terraform output and the pinned image"
	@echo "      digest per environment; it is not removed automatically."
