# GREENER — Infrastructure (Ansible)

Single VPS, everything in Docker Compose, provisioned and versioned with Ansible.
Least-privilege access: OpenVPN, SSH VPN-only, ufw default-deny.

## Layout

```
ansible.cfg            # no default inventory, become on, pipelining, vault_password_file (out of repo)
requirements.yml       # pinned collections: community.general, ansible.posix, community.docker
site.yml               # pure orchestrator: groups -> roles, in order (no inline tasks)
Makefile               # deps, lint, check, deploy, ping, vault-edit, vault-rekey
group_vars/all/
  vars.yml               # shared non-secret vars (all envs)
  users.yml              # declarative system accounts, shared across envs (PUBLIC keys in clear)
inventories/
  production/  staging/
    hosts.yml                    # group greener_vps (the all-in-one VPS)
    group_vars/all/vars.yml      # env-specific vars (e.g. env_name); re-expose vault_*
    group_vars/all/vault.yml     # ENCRYPTED (ansible-vault): the env secrets
    host_vars/
roles/
  common/                        # REAL role: users, groups, sudoers, packages, timezone
  firewall/ ssh/ openvpn/ caddy/ docker/ monitoring/ backups/   # valid stubs
```

## Prerequisites

```bash
pip install ansible ansible-lint yamllint   # ansible-lint & yamllint are needed for `make lint`
make deps                                    # install pinned collections
```

## Environments

The environment is **always explicit**. `ansible.cfg` has no default inventory and the
Makefile defaults to `staging`; production is a deliberate act:

```bash
make check                    # dry-run against staging
make deploy                   # apply to staging
make deploy ENV=production    # apply to production
make ping ENV=production      # connectivity check
```

## Secrets (ansible-vault)

The only "vault" here is **ansible-vault** (file encryption in git). No HashiCorp Vault,
no runtime secret fetching. At deploy time Ansible decrypts in memory and renders
`.env` / Jinja templates on the VPS; containers then read their local `.env`.

Indirection: `vault.yml` (encrypted) holds the real `vault_*` values; `vars.yml`
re-exposes them under neutral names (e.g. `db_password: "{{ vault_db_password }}"`).
**SSH public keys are not secrets** — they live in `users.yml`, never in `vault.yml`.

The passphrase is never in the repo: `ansible.cfg` points at a gitignored
`vault_password_file` (`~/.config/greener/vault_pass`).

```bash
make vault-edit ENV=production     # edit encrypted secrets
make vault-rekey ENV=production    # rotate the passphrase
```

## Governance

**No manual changes on the server — everything goes through a reviewed PR and a replay.**
Offboarding = set the user to `state: absent` in `users.yml`, PR, then `make deploy`.
