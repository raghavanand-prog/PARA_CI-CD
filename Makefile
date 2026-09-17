.PHONY: install test lint security docker-build docker-scan \
        terraform-fmt terraform-validate terraform-plan \
        security-gate security-test clean help

APP_DIR := app
TF_DIR := terraform
TF_ENV_DIR := terraform/environments/dev
IMAGE_NAME := secure-cicd-app:local

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

install: ## Install application dependencies
	cd $(APP_DIR) && npm ci

test: ## Run application unit tests + integration tests
	cd $(APP_DIR) && npm test
	cd $(APP_DIR) && npx jest --config ../tests/integration/jest.config.js

lint: ## Lint application source
	cd $(APP_DIR) && npm run lint

security: ## Run all security scanners + the policy gate (fails closed on missing tools)
	bash security/scripts/run-sast.sh app/src || true
	bash security/scripts/run-dependency-scan.sh app || true
	bash security/scripts/run-secret-scan.sh || true
	bash security/scripts/run-iac-scan.sh terraform || true
	@echo "NOTE: run 'make docker-build' first, then 'make docker-scan' for the container scan."
	bash security/scripts/security-gate.sh

security-gate: ## Evaluate the security gate against whatever reports already exist
	bash security/scripts/security-gate.sh

security-test: ## Test the security-gate policy engine itself against fixture scenarios
	bash tests/security/run-tests.sh

docker-build: ## Build the application's Docker image
	docker build -t $(IMAGE_NAME) $(APP_DIR)

docker-scan: docker-build ## Build the image then run Trivy against it
	bash security/scripts/run-container-scan.sh $(IMAGE_NAME)

terraform-fmt: ## Format-check all Terraform code
	cd $(TF_DIR) && terraform fmt -recursive -check

terraform-validate: ## Validate the root module and the dev environment
	cd $(TF_DIR) && terraform init -backend=false && terraform validate
	cd $(TF_ENV_DIR) && terraform init -backend=false && terraform validate

terraform-plan: ## Plan the dev environment (requires AWS credentials + terraform.tfvars)
	cd $(TF_ENV_DIR) && terraform init && terraform plan -var-file=terraform.tfvars

clean: ## Remove generated/local artifacts
	rm -rf $(APP_DIR)/node_modules $(APP_DIR)/coverage
	find security/reports -type f ! -name '.gitkeep' -delete
	find $(TF_DIR) -type d -name '.terraform' -prune -exec rm -rf {} +
