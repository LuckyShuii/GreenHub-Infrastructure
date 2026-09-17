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
