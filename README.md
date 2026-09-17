# GREENER — Infrastructure (Ansible)

Single VPS, everything in Docker Compose, provisioned and versioned with Ansible.
Least-privilege access: OpenVPN, SSH VPN-only, ufw default-deny.

## Layout

```
ansible.cfg            # no default inventory, become on, pipelining, vault_password_file (out of repo)
requirements.yml       # pinned collections: community.general, ansible.posix, community.docker
site.yml               # pure orchestrator: groups -> roles, in order (no inline tasks)
deploy.yml             # recurring deploy of ONE service, run locally ON THE VPS by the CD webhook
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
  common/                        # REAL: users, groups, sudoers, packages, timezone
  backend/                       # REAL: renders /opt/greener/.env from vault secrets
  docker/                        # REAL: Docker Engine + compose plugin (official APT repo)
  app_stack/                     # REAL: renders + runs the app docker compose stack
  caddy/                         # REAL: host-facing reverse proxy (TLS), proxies to the gateway
  monitoring/                    # REAL: centralised logs (Loki + Alloy + Grafana), own compose project
  webhook/                       # REAL: CD receiver (adnanh/webhook) + the local deploy tooling
  firewall/ ssh/ openvpn/ backups/               # valid stubs
```

## Prerequisites

```bash
pip install ansible ansible-lint yamllint   # ansible-lint & yamllint are needed for `make lint`
make deps                                    # install pinned collections
```

## SSH access (one-time, per developer)

No `ansible_user` is set in the repo: Ansible leaves the account to the SSH client, so you
connect — and sudo — under **your own** `users.yml` account. Declare it once in
`~/.ssh/config`, replacing the login with yours (`lboillot`, `ocorral`, ...):

```
Host greener-prod 51.255.169.129
  User lboillot
  IdentityFile ~/.ssh/id_ed25519
```

Check it with `make ping ENV=production`. A **fresh** VPS has no `users.yml` account yet —
`common` is what creates them — so the very first run goes through the image's built-in
account instead:

```bash
make deploy ENV=production BOOTSTRAP=1   # connects as `ubuntu`, creates every account
make ping ENV=production                 # subsequent runs use your own account
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

## Application stack (Docker Compose)

The `app_stack` role renders the compose file, the nginx gateway config and the postgres
init scripts onto the VPS, then pulls the images and brings the stack up: postgres + backend
+ ai + qdrant behind an internal gateway, only the gateway published (Caddy proxies to it).

It is gated by `app_stack_enabled` (default **false**), so a plain `make deploy` renders the
files without pulling images that may not exist yet. To actually start the stack:

```bash
# whole play, stack enabled (staging)
ansible-playbook -i inventories/staging/hosts.yml site.yml -e app_stack_enabled=true

# only the app_stack role (every role is tagged)
ansible-playbook -i inventories/staging/hosts.yml site.yml --tags app_stack -e app_stack_enabled=true

# production
ansible-playbook -i inventories/production/hosts.yml site.yml --tags app_stack -e app_stack_enabled=true
```

Or set `app_stack_enabled: true` in `inventories/<env>/group_vars/all/vars.yml` and just run
`make deploy`.

Images live in the private repo `lucasboillot/greenhub` (tags `backend-<sha>` / `ai-<sha>`);
pin a build per service with `-e app_stack_backend_version=<sha>` / `-e app_stack_ai_version=<sha>`.
Prereq: the images must already be published (by CI, or a manual `docker push`).

## Continuous deployment

Provisioning is a **push** run from a workstation; the **recurring** deploy runs on the VPS
itself. After publishing an image, the pipeline POSTs to the deploy endpoint:

```
POST https://deploy.<domain>/hooks/deploy-backend   (or /hooks/deploy-ia)
X-Deploy-Token: <VPS_DEPLOY_KEY>
{"version": "<commit sha>"}
```

Caddy terminates TLS and forwards to the `webhook` daemon on `127.0.0.1:9000`, which checks the
token and the SHA — anything else is a `403` with nothing executed — then runs `deploy.yml`
locally, as the `deploy` account, under a `flock` so two pipelines cannot deploy at once. The CI
never opens an SSH session to the VPS: `VPS_DEPLOY_KEY` is an **HTTP token, not an SSH key**.

```bash
journalctl -u greener-webhook -f            # the deploy trail
cat /opt/greener/deployed-versions.yml      # what is running right now
```

The token lives in the env vault as `vault_deploy_webhook_token` and must be handed to the
backend and AI repos as the `VPS_DEPLOY_KEY` GitHub secret. See `roles/webhook/README.md` for
the full contract, the rollback procedure and the on-host layout.

### Local dev stack (no Ansible)

```bash
docker compose -f docker-compose.dev.yml up -d                            # full: postgres + backend + ai + qdrant + gateway (built from the sibling repos)
docker compose -f docker-compose.dev.yml up -d postgres backend gateway   # skip the heavy AI build
```

The gateway is published on `127.0.0.1:8080`, so the API answers on
`http://localhost:8080/api/...` — the **same paths** as production and as the backend repo's
own compose (`http://localhost:8000/api/...`), because the FastAPI app owns the `/api`
prefix and the gateway forwards the URI untouched. Backend devs who only need db + API can
stay in the backend repo; use this stack to exercise the gateway and the AI service.

The AI service needs qdrant and indexes it at startup **before** it accepts any connection:
the first `up` with an empty `qdrant_storage` volume takes many minutes and downloads
reference images from the internet. Keep the volume between runs. See
`roles/app_stack/README.md` for the details and the open points on the AI image.

## Centralised logs (Loki + Alloy + Grafana)

The `monitoring` role runs its own compose project in `/opt/greener-monitoring`, separate
from `app_stack` so a monitoring change never restarts the application. Alloy collects,
Loki stores, Grafana displays — datasource and dashboards are provisioned from files, never
clicked in the UI.

Two things are provisional until their prerequisites exist (SCRUM-129):

- **Access.** No VPN yet, so Grafana publishes on `127.0.0.1:3000` and Caddy stays the only
  host-facing service. Reach it through a tunnel:
  ```bash
  ssh -L 3000:127.0.0.1:3000 lboillot@<vps>   # then http://localhost:3000
  ```
  A public vhost exists behind `grafana_public` (`group_vars/all/vars.yml`) and is **off by
  default** — with no VPN, its only protection would be the Grafana admin password.
- **Sources.** No application is running yet, so a systemd timer writes synthetic JSON logs
  to `/var/log/greener-sample/` and Alloy tails those. Setting
  `monitoring_sample_logs_enabled: false` stops the timer and removes every trace of it.

```bash
ansible-playbook -i inventories/production/hosts.yml site.yml --tags monitoring
ansible-playbook -i inventories/production/hosts.yml site.yml --tags logsample  # generator only
```

The bring-up ends by asking Grafana to run a real query against the Loki datasource, so a
broken config fails the run instead of leaving a restart loop. See
`roles/monitoring/README.md`.

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
