# `backend` role

**Materializes vault secrets into `/opt/greener/.env` for the FastAPI backend.**

The app **never** knows about ansible-vault or `vault_*` names: the contract between infra
and app is **env var names only**, mirrored in the backend repo's `.env.example`. This role
renders the clear-text indirection vars (`db_password`, set in `group_vars/all/vars.yml`
from `vault_db_password`) into a plain `.env` file at deploy time.

## What it does

- Ensures `/opt/greener` exists.
- Renders `templates/env.j2` to `/opt/greener/.env` (`0600`, root-only until the deploy
  account lands — SCRUM-53).
- Sets `diff: false` on the template task so secrets never land in `--check --diff` output
  or CI logs.

V1 scope: only the `.env`. The docker compose deployment of the app itself comes later.

## Key variables (see `defaults/main.yml`)

| Variable | Default | Notes |
| --- | --- | --- |
| `backend_app_dir` | `/opt/greener` | On-host app directory. |
| `backend_db_host` | `postgres` | Compose service name; override per env if needed. |
| `backend_db_port` | `5432` | |
| `backend_db_name` | `greener` | |
| `backend_db_user` | `greener` | |

Secrets consumed (via indirection, never `vault_*` directly): `db_password`.

## Contract with the app

| Env var | Source |
| --- | --- |
| `APP_ENV` | `env_name` (per-env vars) |
| `DB_HOST` / `DB_PORT` / `DB_NAME` / `DB_USER` | role defaults |
| `DB_PASSWORD` | `db_password` → `vault_db_password` |

Adding a variable = update `env.j2` here **and** `.env.example` in the backend repo, same PR
train, or the app breaks silently.

## Verify

```sh
# File is present, root-only:
sudo ls -l /opt/greener/.env    # -rw------- root root

# Names match the contract (values stay on the server):
sudo grep -oE '^[A-Z_]+' /opt/greener/.env

# Idempotence: a second run must report changed=0:
make deploy ENV=production
```
