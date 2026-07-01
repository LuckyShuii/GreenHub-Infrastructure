# Environment is explicit and defaults to staging. Prod is always deliberate:
#   make deploy ENV=production
ENV ?= staging
INVENTORY := inventories/$(ENV)/hosts.yml
VAULT := inventories/$(ENV)/group_vars/all/vault.yml

.PHONY: deps lint check deploy ping vault-edit vault-rekey

deps: ## Install pinned collections
	ansible-galaxy collection install -r requirements.yml

lint: ## Run yamllint + ansible-lint
	yamllint .
	ansible-lint

check: ## Dry-run against $(ENV) (no changes applied)
	ansible-playbook -i $(INVENTORY) site.yml --check --diff

deploy: ## Apply against $(ENV)
	ansible-playbook -i $(INVENTORY) site.yml

ping: ## Connectivity check against $(ENV)
	ansible -i $(INVENTORY) all -m ping

vault-edit: ## Edit the $(ENV) encrypted secrets
	ansible-vault edit $(VAULT)

vault-rekey: ## Rotate the vault passphrase for the $(ENV) secrets
	ansible-vault rekey $(VAULT)
