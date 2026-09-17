# `monitoring` role

**Centralised logs: Loki (store) + Alloy (collector) + Grafana (UI), in their own docker
compose project.**

```
/var/log/greener-sample/*.log ──▶ Alloy ──push──▶ Loki ──query──▶ Grafana
   (synthetic, temporary)                                          │
                                                        127.0.0.1:3000 (loopback)
                                                                   │
                                                          ssh -L tunnel

Grafana Alerting ──webhook──▶ Discord #alerting   (SCRUM-130)
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

All of them follow the repo's standard indirection — `vault_*` (encrypted, per env) → a
neutral name in `group_vars/all/vars.yml` → rendered into `/opt/greener-monitoring/.env`
(0600) with `diff: false` + `no_log`:

| Vault key | Neutral name | What it is |
|---|---|---|
| `vault_grafana_admin_password` | `grafana_admin_password` | The bootstrap `admin` account |
| `vault_grafana_user_passwords` | `grafana_user_passwords` | One password per person (see below) |
| `vault_discord_alert_webhook` | `discord_alert_webhook` | The alert channel webhook |

Every non-secret Grafana setting sits in the compose file instead, so the env file holds
nothing but credentials.

## Grafana is provisioned, never clicked

The datasource (uid `loki`) and the dashboards are files, bind-mounted read-only and
provisioned at boot with `editable: false` / `allowUiUpdates: false`. A rebuilt container
comes back identical, and a change made in the UI does not survive a restart — it belongs in
`files/grafana/dashboards/` and in a PR.

## Alerting goes to one Discord channel

SCRUM-87 delivered where logs are *stored* and *read*; it raised nothing. This role now
also provisions the **channel** alerts leave by — a single Discord webhook pointed at a
dedicated `#alerting` channel. The rules that actually fire into it are SCRUM-131; what
lives here is the contact point and the routing.

Discord rather than e-mail, deliberately: it gives mobile push for free, and there is no
SMTP relay to operate, no API key to rotate at a provider, and no deliverability to
babysit.

### The webhook URL never lands in a readable file

Grafana interpolates `$VAR` inside provisioning files. So the URL stays in
`/opt/greener-monitoring/.env` (0600, `diff: false` + `no_log`) and
`provisioning/alerting/contactpoints.yml` only ever says:

```yaml
settings:
  url: $GREENER_DISCORD_ALERT_WEBHOOK
```

which is why that file can stay an ordinary 0644 config, readable by the Grafana container
and fully visible in `--check --diff`. Treat the URL as a credential: anyone holding it can
post in the channel.

### The root notification policy is replaced

Provisioning a policy **overrides Grafana's built-in default route**, which points at an
email contact point that does not exist here. That is the intent — everything this stack
raises goes to the one channel, and nothing can be routed to a receiver nobody reads.

Timings are tuned for a single VPS with one person on call: group by
`(alertname, env, service)` so a rule matching six containers posts once, and re-notify
about a still-firing group only every 4 h. A channel that cries every minute is a channel
that gets muted.

### Two verifications, because they prove different things

| Check | Proves | When |
|---|---|---|
| `GET .../provisioning/contact-points` | Grafana *parsed* the file | every run |
| `POST` to the webhook itself | the URL behind it is live | on change only |

An unparseable provisioning file leaves Grafana up and simply without the contact point,
which is why the first check asks Grafana what it loaded instead of trusting the file on
disk. And a well-formed contact point says nothing about the URL behind it: a revoked or
mistyped webhook fails only once something is really sent, hence the second check.

The second one posts a real message, so it is gated on change: a replay that changes
nothing leaves the channel silent. Set `monitoring_alert_test_on_change: false` to suppress
it entirely.

### Handlers are flushed before verifying

Compose only recreates a container when the compose *file* changes, and a bind-mounted
config changing is invisible to it — so the render tasks notify `Restart grafana`. Handlers
normally run at the very end of the play, i.e. *after* these checks, which would then
inspect a Grafana that had not yet read the file just written for it. An explicit
`meta: flush_handlers` sits between the bring-up and the verifications. This also fixes the
same latent problem for the datasource and the dashboards.

### Turning it off actually turns it off

Deleting the provisioning files is **not** how you disable alerting: Grafana keeps
provisioned resources in its own database, so a contact point whose file is gone keeps
existing and keeps being notified. `monitoring_alerting_enabled: false` therefore renders a
teardown file that resets the root notification policy — routing reverts to Grafana's
built-in default receiver, which goes nowhere here since no SMTP is configured.

The contact point object itself is left behind on purpose: Grafana refuses to delete one
while a policy still references it, and the ordering of the two operations within a single
provisioning pass is not guaranteed. An unreferenced contact point receives nothing.

### Setting it up

In Discord: **Edit channel → Integrations → Webhooks → New Webhook**, copy the URL, then

```bash
# add   vault_discord_alert_webhook: "https://discord.com/api/webhooks/..."
make vault-edit ENV=production
```

A missing or malformed value fails the run with an explanation rather than deploying a
stack that cannot tell you anything.

## Alert rules

Rules are code, like the dashboards: `provisioning/alerting/rules.yml`, rendered from
`monitoring_alert_rules_enabled`. If the UI is easier for drafting one, use it — then
**Alerting → Alert rules → Export** in provisioning format, commit the YAML here, and
delete the UI rule.

Everything queries Loki, because Loki is the only datasource that exists yet. Real
container-state rules need metrics ([SCRUM-99](https://greener-epitech.atlassian.net/browse/SCRUM-99)).

| Rule | Fires when | `noDataState` |
|---|---|---|
| `greener-error-rate` | more than `monitoring_alert_error_threshold` error lines per service in the window | `OK` |
| `greener-silent-<service>` | a watched service stops logging | `Alerting` |

### Testing them while only fake logs exist

`greener-error-rate` **will not fire** on the synthetic generator: it averages ~2.5 error
lines per service per 5 min, well under the default threshold of 10. That is expected. To
watch the whole path fire, deploy once with `-e monitoring_alert_error_threshold=0`.

The silence rules are the better end-to-end test, because you control both directions:

```bash
sudo systemctl stop greener-logsample.timer    # ~10 min -> 4 FIRING alerts in Discord
sudo systemctl start greener-logsample.timer   # -> the matching RESOLVED messages
```

`sudo` is not optional here. Named accounts get sudo from a NOPASSWD drop-in
(`roles/common/tasks/sudoers.yml`) and are deliberately **not** in the `sudo` group, which
is what polkit treats as administrator. A bare `systemctl stop` therefore falls through to
polkit, which asks for the password of an account these key-only users do not have.

### Why one silence rule per service

A dead service stops producing a Loki stream, so it **disappears from the query result**
rather than reporting zero. A single rule aggregating every service would therefore never
notice one of them dying — the series it should complain about is simply not there.

One rule per expected service turns that disappearance into `NoData` on a rule that already
names the service, and `noDataState: Alerting` raises it. The expected list is declarative:

```yaml
monitoring_alert_watched_services: [backend, ai, postgres, caddy]
```

Their labels (`service`, `env`) are **static on the rule**, not taken from the query: on
`NoData` there is no series and therefore no query labels, so without them the Discord
message could not say *which* service went quiet and the notification policy could not
group on it.

### The assumption it makes, and why it is tied to the generator

**It treats silence as death, which only holds for a source that logs unconditionally.**
The generator does — 1 to 5 lines per service per minute, whatever happens. The real
services do not: a FastAPI backend logs on request, so at 03:00 with no users it emits
nothing and this rule would page for a service that is perfectly healthy. Caddy and the AI
service behave the same way, and Postgres is near-silent at rest.

So `monitoring_alert_silence_enabled` defaults to **following the generator**:

```yaml
monitoring_alert_silence_enabled: "{{ monitoring_sample_logs_enabled }}"
```

The day SCRUM-129 turns the sample logs off, these rules are deleted with them (by uid, see
below) and cannot reach real traffic through forgetfulness. A pager that cries at 03:00 for
a healthy service is worse than no pager at all — it teaches the team to ignore the channel.

It is also slow by nature: it must wait out the window before it can conclude anything.

### What actually detects a dead service

`app_stack` **already defines Docker healthchecks** for `backend`, `postgres`, `qdrant` and
`ai`. Docker probes them continuously, independently of traffic, and knows their state at
every moment. The gap is not missing surveillance — it is that this state, which Docker
already computes, is not exposed to Grafana. That is SCRUM-99, and it is why that ticket
was pulled into V1.

### Disabling them deletes them

Same trap as the contact point: removing `rules.yml` does not remove the rules, Grafana
keeps them in its database and they keep evaluating and notifying.
`monitoring_alert_rules_enabled: false` therefore renders a teardown naming every uid in
`deleteRules`. Apply that state **before** deleting rules from this role, or they live on
with nothing left to manage them.

### The run fails on a rule Grafana refused

A malformed query model or an unknown datasource does not stop Grafana from starting — the
rule is just absent. So the role asks for the list of provisioned rules and compares it
against the uids it claims to deploy. A rejected rule fails the run instead of looking
deployed.

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
task notifies its own container (`Restart loki` / `Restart alloy` / `Restart grafana`)
rather than relying on the bring-up to notice.

## Loki configuration notes

- **Retention is enforced by the compactor**, not by `limits_config` alone: without
  `compactor.retention_enabled`, data is merely marked expired and never deleted.
- `schema_config.configs[].from` must stay in the past and must **never** be edited once
  data exists under it — add a new entry instead.
- Labels are kept to `service`, `level`, `env` and `agent`. Every label combination is a
  separate Loki stream, so a high-cardinality label (request id, duration) would blow up the
  index. Everything else stays in the log line and is queried with `| json`.
