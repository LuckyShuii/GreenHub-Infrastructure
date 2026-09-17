# `monitoring` role

**Centralised logs: Loki (store) + Alloy (collector) + Grafana (UI), in their own docker
compose project.**

```
/var/log/greener-sample/*.log ──▶ Alloy ──push──▶ Loki ──query──▶ Grafana
   (synthetic, temporary)                                          │
                                                        127.0.0.1:3000 (loopback)
                                                                   │
                                                          ssh -L tunnel
```

## Scope today (SCRUM-87) vs. later (SCRUM-129)

Two things are deliberately provisional, because their prerequisites do not exist yet:

| | Today (SCRUM-87) | After [SCRUM-129](https://greener-epitech.atlassian.net/browse/SCRUM-129) |
|---|---|---|
| Access | Grafana on `127.0.0.1:3000`, reached by SSH tunnel | Bound to the VPN IP (needs SCRUM-58) |
| Sources | A systemd timer fabricates JSON log lines | Real container logs + the systemd journal |

Everything else — the compose project, the Loki config, the Alloy pipeline, the provisioned
datasource and dashboard — is meant to survive that ticket unchanged.

## Why Alloy and not Promtail

Promtail reached end of life in March 2026 and Grafana's own migration path is Alloy, so
standing Promtail up would mean replacing it immediately. `loki.process` here already uses
the stage names Promtail used, so nothing about the pipeline is Alloy-specific except the
file format.

## Separate compose project

This stack lives in `/opt/greener-monitoring`, **not** `/opt/greener`. Two compose projects
in one directory would fight over `docker-compose.yml`, and more importantly a monitoring
change must never restart the application (nor the reverse). The network
(`greener_monitoring`) is separate too: the collector reads log *files* on the host, not the
application containers, so the two have no reason to touch yet. SCRUM-129 attaches Alloy to
`greener_internal` when it switches to Docker discovery.

## Reaching Grafana

No VPN yet, so Grafana publishes on loopback only and Caddy stays the single host-facing
service. Open a tunnel from your workstation:

```bash
ssh -L 3000:127.0.0.1:3000 lboillot@<vps>
# then browse http://localhost:3000  (user: admin, password: vault_grafana_admin_password)
```

A public vhost (`grafana.<caddy_domain>`) exists behind the shared `grafana_public` toggle
in `group_vars/all/vars.yml`, consumed by both this role (Grafana's root URL) and the
`caddy` role (the vhost itself). **It is off by default and should stay off**: without the
VPN its only protection is the Grafana admin password. Turning it on also requires a DNS
record, or ACME cannot issue the certificate.

## Secrets

Only one: the Grafana admin password. It follows the repo's standard indirection —
`vault_grafana_admin_password` (encrypted, per env) → `grafana_admin_password`
(`group_vars/all/vars.yml`) → rendered into `/opt/greener-monitoring/.env` (0600) with
`diff: false` + `no_log`. Every non-secret Grafana setting sits in the compose file instead,
so the env file holds nothing but the credential.

## Grafana is provisioned, never clicked

The datasource (uid `loki`) and the dashboards are files, bind-mounted read-only and
provisioned at boot with `editable: false` / `allowUiUpdates: false`. A rebuilt container
comes back identical, and a change made in the UI does not survive a restart — it belongs in
`files/grafana/dashboards/` and in a PR.

## One Grafana account per person

Datasources and dashboards are provisioned from files. **Users cannot be** — Grafana keeps
them in its own database and offers no file provisioning for them, so this role drives its
admin API instead, from the same declarative list as the system accounts:

```yaml
# group_vars/all/users.yml
- name: ecouy
  state: present
  sudo: false
  grafana: Editor      # Admin | Editor | Viewer — omit the field for no account at all
```

| Field | Result |
|---|---|
| `grafana: <role>` | Account exists with that org role |
| no `grafana:` field | No Grafana account (the non-human `deploy` account, for instance) |
| `state: absent` | Account deleted — the same offboarding gesture as the system account |

A replay reports no change: the role only POSTs accounts that are missing, only PATCHes a
role that actually differs, and only DELETEs logins this repo declares (an account somebody
created by hand for another reason is left alone).

### Why Editor for the devs, not Viewer

**Explore — the ad-hoc log querying view, which is the whole point during an incident — is
not available to Viewers** in Grafana's default configuration. A dev who can only look at
the prepared dashboard cannot chase down an unexpected problem. Our own dashboards stay
locked (`allowUiUpdates: false`), so an Editor can build their own without being able to
overwrite the provisioned ones.

### One password per person, managed state

Each account has **its own** password, in the env vault:

```yaml
# inventories/<env>/group_vars/all/vault.yml   (encrypted)
vault_grafana_user_passwords:
  lboillot: "..."
  ecouy: "..."
```

**The vault is the truth and every replay restores it.** Somebody who changes theirs in the
UI has it reverted on the next deploy, and the run reports that as a change. Hand the
passwords out yourself; read them with `make vault-edit ENV=<env>`.

There is **no shared fallback**. An account carrying a `grafana:` role with no entry in the
map fails the run with its login named — quietly giving two people the same credentials
would defeat the point of per-person accounts.

Grafana never exposes the password hash, so "has it drifted?" is answered the only way
available — by trying to authenticate as that user with the expected password. A 401 means
drift and triggers the reset; a 200 means nothing to do. That keeps the task honestly
idempotent rather than blindly resetting on every run.

One honest limitation: Grafana OSS has no setting to hide the "change password" button, so
a user can still change it. They simply do not get to keep it.

### Two gotchas

- **Org Admin is not Grafana server admin.** `grafana: Admin` grants administration *within
  the organisation* (users, datasources). Server-level administration stays with the
  bootstrap `admin` account, whose password is `vault_grafana_admin_password`.
- **Accounts live in the `grafana_data` volume.** Destroying it erases them; the next replay
  recreates them, but changed passwords and personal preferences are gone.

```bash
ansible-playbook -i inventories/production/hosts.yml site.yml --tags grafana-users
```

## The synthetic log generator

`greener-logsample.timer` runs `/usr/local/bin/greener-logsample` every minute, appending a
few JSON lines per fake service to `/var/log/greener-sample/`. It exists purely to prove the
chain end to end while no application runs. It trims its own files (no logrotate for a
throwaway source) and the unit is confined with `ProtectSystem=strict`.

Setting `monitoring_sample_logs_enabled: false` does not just stop writing — it stops and
disables the timer and deletes the script, the units and the log directory. Apply that
state **before** deleting the code in SCRUM-129, otherwise a timer stays behind on the host
with nothing left to manage it.

## Running it

```bash
make check ENV=production                                   # dry run, whole playbook
ansible-playbook -i inventories/production/hosts.yml site.yml --tags monitoring
ansible-playbook -i inventories/production/hosts.yml site.yml --tags logsample  # generator only
```

On the host:

```bash
docker compose -f /opt/greener-monitoring/docker-compose.yml ps
systemctl list-timers greener-logsample.timer
tail -f /var/log/greener-sample/backend.log
```

## Bind-mounted configs need explicit restarts

Compose sees no change when the *content* of a bind-mounted file changes, so each render
task notifies its own container (`restart loki` / `restart alloy` / `restart grafana`)
rather than relying on the bring-up to notice.

## Loki configuration notes

- **Retention is enforced by the compactor**, not by `limits_config` alone: without
  `compactor.retention_enabled`, data is merely marked expired and never deleted.
- `schema_config.configs[].from` must stay in the past and must **never** be edited once
  data exists under it — add a new entry instead.
- Labels are kept to `service`, `level`, `env` and `agent`. Every label combination is a
  separate Loki stream, so a high-cardinality label (request id, duration) would blow up the
  index. Everything else stays in the log line and is queried with `| json`.
