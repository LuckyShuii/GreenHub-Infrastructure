# Environment is explicit and defaults to staging. Prod is always deliberate:
#   make deploy ENV=production
ENV ?= staging
INVENTORY := inventories/$(ENV)/hosts.yml
VAULT := inventories/$(ENV)/group_vars/all/vault.yml

# Remote account: unset, so the SSH client resolves it from each dev's ~/.ssh/config and
# everyone acts under their own users.yml account. A fresh VPS has none of those accounts
# yet, so bootstrap it through the image's built-in one: make deploy BOOTSTRAP=1
BOOTSTRAP ?=
CONNECT := $(if $(BOOTSTRAP),-e ansible_user=ubuntu)

.PHONY: deps lint check deploy ping vault-edit vault-rekey

deps: ## Install pinned collections
	ansible-galaxy collection install -r requirements.yml

lint: ## Run yamllint + ansible-lint
	yamllint .
	ansible-lint

check: ## Dry-run against $(ENV) (no changes applied)
	ansible-playbook -i $(INVENTORY) $(CONNECT) site.yml --check --diff

deploy: ## Apply against $(ENV)
	ansible-playbook -i $(INVENTORY) $(CONNECT) site.yml

ping: ## Connectivity check against $(ENV)
	ansible -i $(INVENTORY) $(CONNECT) all -m ping

vault-edit: ## Edit the $(ENV) encrypted secrets
	ansible-vault edit $(VAULT)

vault-rekey: ## Rotate the vault passphrase for the $(ENV) secrets
	ansible-vault rekey $(VAULT)
