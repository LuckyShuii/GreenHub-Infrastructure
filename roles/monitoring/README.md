# `monitoring` role

**Logs and metrics: Loki + Prometheus (stores), Alloy (the one collector), Grafana (UI),
in their own docker compose project.**

```
LOGS
greener_* containers ──Docker API──┐
  (gateway, backend, ai,           │
   postgres, qdrant)               ├──▶ Alloy ──push──▶ Loki ─────┐
systemd journal ───────────────────┘        │                     │
  (caddy, greener-webhook, docker)          │                     ├─query─▶ Grafana
                                            │                     │            │
METRICS                                     │                     │   127.0.0.1:3000
node exporter   ──┐                         │                     │     (loopback)
cAdvisor        ──┴── inside Alloy ─────────┴─remote write─▶ Prometheus        │
                                                                ssh -L  ·  grafana.<domain>

Grafana Alerting ──webhook──▶ Discord #alerting   (SCRUM-130)
```

## What is real and what is still provisional

The sources are real since [SCRUM-129](https://greener-epitech.atlassian.net/browse/SCRUM-129):
the application containers are read through the Docker API and the services that run
natively are read from the systemd journal. The synthetic generator that proved the chain
end to end under SCRUM-87 is off, and its teardown removes it from the host.

[SCRUM-99](https://greener-epitech.atlassian.net/browse/SCRUM-99) added **metrics** next to
them, which is what finally answers the two questions logs cannot: *how much of the machine
is left*, and *is this container alive*. Three dashboards now: `GREENER — Logs`,
`GREENER — Machine hôte`, `GREENER — Services`.

One thing stays provisional, because its prerequisite does not exist yet:

| | Today | After [SCRUM-58](https://greener-epitech.atlassian.net/browse/SCRUM-58) (VPN) |
|---|---|---|
| Access | Grafana on `127.0.0.1:3000`, plus a public vhost — an accepted risk, see below | Bound to the VPN IP, `grafana_public` deleted |

## Why Alloy and not Promtail

Promtail reached end of life in March 2026 and Grafana's own migration path is Alloy, so
standing Promtail up would mean replacing it immediately. `loki.process` here already uses
the stage names Promtail used, so nothing about the pipeline is Alloy-specific except the
file format.

## The two real sources

### Containers: an allow-list on the compose project

`discovery.docker` sees **every** container on the host, which is not what we want twice
over: this VPS also runs containers unrelated to GREENER, and the monitoring stack's own
three must not ship their logs into the Loki those logs are about — Alloy reporting a push
failure by pushing it is a loop.

So the filter is a `keep` on `com.docker.compose.project == greener`, an **allow**-list.
A deny-list would need updating the day somebody starts one more unrelated container; this
one is already correct then. The compose service name becomes the `service` label, so
`backend`, `postgres`, `ai`, `qdrant` and `gateway` appear under the names they have in
`app_stack`.

### Native services: an allow-list on the unit

Caddy, the CD webhook and the Docker daemon have no container to read, so they come from
the **systemd journal** (persistent, under `/var/log/journal`). Same allow-list shape, for
a different reason: on a VPS whose SSH is still reachable from the internet, most of the
journal is `sshd` refusing scans. `monitoring_journal_units` is the list; adding one is a
one-line change.

`caddy.service` is relabelled to `caddy`, so a native service reads exactly like a
containerised one and a single dashboard query covers both. `source` (`docker` /
`journal`) is the label that tells them apart.

### Alloy runs as root, and what that costs

Both sources are root-owned on the host — the Docker API socket (`root:docker`) and the
journal (`root:systemd-journal`) — so the container runs as root.

Be honest about the consequence: **a process that can call the Docker API is
root-equivalent on the host**, because it can start a privileged container. The `:ro` on
the socket mount is close to decorative — it protects the socket *file*, not the API behind
it. Mounting a socket read-only does not make the API read-only.

What makes it acceptable today: Alloy accepts no input from the network (it publishes
nothing, and its own UI stays inside `greener_monitoring`), it only ever *reads* logs, and
its config is rendered by this role rather than fetched. What would actually remove the
privilege is a docker-socket proxy exposing only `GET /containers/*/logs` to Alloy —
worth a ticket, not worth blocking the real logs on.

### Levels are matched, not parsed

Five services, five formats, and not one of them is JSON:

| Service | Shape | Example |
|---|---|---|
| `backend` | uvicorn | `INFO:     127.0.0.1:52394 - "GET /health HTTP/1.1" 200 OK` |
| `ai` | python `logging` | `2026-09-21 12:50:24,585 [INFO] src.indexer: ...` |
| `postgres` | pid + level | `2026-09-21 12:50:01.885 UTC [1] LOG:  ...` |
| `qdrant` | rust tracing | `2026-09-21T12:50:24.567187Z  INFO actix_web...: ...` |
| `gateway` | nginx, **two** formats in one stream | combined access log, and `2026/09/21 12:51:23 [error] ...` |
| `caddy` | JSON | `{"level":"info","ts":...,"msg":"..."}` |
| `greener-webhook` | Ansible output | `fatal: [greener-prod]: FAILED! => ...` |

So the level is assigned by **matching the line**, per service, rather than by extracting a
field and normalising it. Two reasons:

- There is no single field to extract. A per-service regex would have to be written anyway,
  and when one of those formats drifts, a regex that no longer matches yields *no* level —
  and a stream with no `level` label is invisible to every dashboard and rule that filters
  on one. A match that no longer matches just stops upgrading the level.
- The vocabularies differ and have to be mapped regardless: `WARNING` and `WARN` and
  `[warn]` are the same thing; Postgres `LOG`, `NOTICE`, `DETAIL` and `HINT` are *not*
  levels in that sense and stay `info`.

Everything starts at `info`, and the stages run in **ascending severity**, so a later match
overrides an earlier one and a line ends up labelled with the worst thing it says about
itself. The nginx access log has no level of its own, so its **status code** becomes one: a
5xx is an error whatever nginx logged it as, a 4xx is a warning.

Every pattern is anchored to where the level actually appears, which is the difference
between a useful label and a coin flip — `GET /api/debug` must not become a `debug` line,
and `?code=500` in a query string must not become an error.

### Two escaping traps, and why a local run is the only proof

A `stage.match` selector is a LogQL query inside an Alloy string, so there are two escaping
layers. Both bite:

- Alloy strings follow **Go's** escape rules, where `\.` is not a valid escape — an
  unescaped regex has to live in a **raw string** (backticks).
- The LogQL parser *inside* the match stage **rejects backtick strings of its own**, so the
  line filter must be double-quoted with LogQL-level escaping.

Raw string outside, double quotes inside, one level of `\\`. And `alloy fmt` **accepts the
wrong version happily** — it validates Alloy syntax, not the LogQL nested in a string. The
only thing that proves a change here is running it:

```bash
# render the template, then hand the real pipeline a file of real log lines
docker run --rm -v "$PWD/cfg:/cfg:ro" grafana/alloy:v1.19.2 fmt /cfg/config.alloy
docker run --rm -v "$PWD/test:/cfg:ro" -v "$PWD/logs:/logs:ro" \
  grafana/alloy:v1.19.2 run /cfg/config.alloy --storage.path=/tmp/alloy
```

Swap the two real sources for `loki.source.file` targets carrying a `service` label, send
the pipeline to `loki.echo` instead of `loki.write`, and every entry is printed with the
labels it came out with. `logging { level = "info" }` is required — `loki.echo` writes
through the logger, and at `warn` it prints nothing and looks like silence.

### Timestamps come from Docker and the journal, not from the line

There is **no `stage.timestamp`** anywhere, deliberately. One synthetic format was safe to
parse; five real ones are not, and the AI service's carries no timezone at all. A
mis-parsed timestamp does not fail loudly — it files logs at the wrong time, or trips
Loki's `reject_old_samples` and drops them silently. Docker and the journal both stamp
every line themselves, within milliseconds of the event, and that stamp cannot be
malformed. The application's own timestamp stays in the line, queryable.

### An idle service produces nothing, and that is not a bug

`loki.source.docker` tails a container from where it is **now**; it does not replay the
history of a container it has just discovered. Combine that with services that only log on
demand and a freshly restarted Alloy shows a dashboard with `backend`, `gateway`, `caddy`
and `docker` on it and **nothing** for `ai`, `postgres`, `qdrant` or `greener-webhook`.

That was observed right after the SCRUM-129 deploy and it was correct: those four had not
written a line since before Alloy started — an idle Postgres does not even checkpoint, and
the CD webhook only speaks during a deploy.

How to tell that apart from a real failure, without guessing:

```bash
# Does Alloy actually hold the container as a target? (all five app containers listed = wired)
docker exec greener-monitoring-grafana-1 \
  wget -qO- 'http://alloy:12345/api/v0/web/components/loki.source.docker.app'

# Has the container written anything at all lately?
docker logs greener-postgres-1 --tail 1 --timestamps
```

If the target is there and the container is silent, there is nothing to collect. This is
also why the metrics rules, not the log rules, are what tells you a service is down.

### The healthcheck noise is dropped, not stored

The backend probes itself every 10 s and uvicorn logs every probe: ~8 600 lines a day that
only say "the probe ran". Those are dropped in the pipeline (`stage.drop`), not filtered
out at query time — a line nobody will ever read should cost neither index nor disk. The
pattern is anchored on the loopback client, so a real `/health` call from outside is still
collected. `monitoring_drop_healthcheck_logs: false` keeps them.

## Metrics: the exporters live inside Alloy

The ticket names *Prometheus + Node Exporter + cAdvisor*. What is deployed is Prometheus as
a **store** and the two exporters **inside Alloy**, which is the same three things with one
fewer container and one fewer privilege.

The reasoning: node_exporter and cAdvisor need root, the host's `/proc` and `/sys`, and the
Docker socket. Alloy already has all of it for the logs. A separate cAdvisor container would
have to be granted `privileged: true` to obtain privileges Alloy holds anyway — so the
separate container adds an attack surface without removing one. One agent, one set of host
mounts, one thing to reason about.

Prometheus therefore scrapes almost nothing: Alloy remote-writes the series in
(`--web.enable-remote-write-receiver`). The one thing it does scrape is itself, so "is the
store healthy, is it dropping samples" is answerable from the same place as everything else.

### The cgroup v2 trap, which fails silently

**`cgroup: host` on the Alloy container is load-bearing.** Docker gives a container a
*private* cgroup namespace by default on cgroup v2 (this host runs kernel 6.8), and in that
namespace the container sees only its own cgroup as `/`. cAdvisor then reports a single
series for itself and **nothing at all for the other containers** — no error, no warning,
just an empty services dashboard.

Verified rather than assumed: without the setting,
`container_cpu_usage_seconds_total` comes back with `id="/"` and no `name` label.

### The containerd trap, which does NOT fail silently

`cgroup: host` is necessary and **not sufficient**, and this one cost a production page
before it was understood. The two failures look identical from the dashboards — one series
for the root cgroup, nothing per container — and have nothing to do with each other.

Docker on this host uses the **containerd snapshotter**: `docker info` reports the storage
driver as `overlayfs`, not `overlay2`. In that mode cAdvisor cannot resolve a container's
filesystem layers from `/var/lib/docker` alone; it asks containerd directly. Discovery still
works — cAdvisor finds every `/system.slice/docker-<id>.scope` — and then **throws the
container away** when the client cannot be built:

```
level=error msg="Failed to create existing container: /system.slice/docker-<id>.scope:
  unable to create containerd client for overlayfs storage driver: containerd: cannot unix
  dial containerd api service: dial unix /run/containerd/containerd.sock: connect: no such
  file or directory" component_id=prometheus.exporter.cadvisor.containers
```

Once per container, per scrape, at `level=error` in Alloy's own log — so unlike the cgroup
trap this one is loud, provided you read the collector's log instead of only its output.
The fix is the socket mount; Alloy's default `containerd_host` is already this exact path
(`monitoring_containerd_socket`), so no Alloy configuration changes.

**What made it a page rather than a failed deploy** is that `absent()` cannot tell "this
container is dead" from "cAdvisor never saw it". With no `container_last_seen` series for
the project, every `greener-container-down-<svc>` rule fired at once on a host where all
five containers were `Up (healthy)`. Five simultaneous container-down alerts are therefore
worth reading as *the collector is blind*, not as five dead containers — a single dead
container fires exactly one. The probe below now asserts the per-container series, so the
same mistake fails the deploy instead.

### Host paths, or the metrics describe the collector

`/proc` and `/sys` are separate mounts, so bind-mounting `/` alone hands Alloy an **empty**
`/host/proc`. Each is mounted explicitly, and the root mount carries `propagation: rslave`
— without it a bind of `/` does not carry its submounts and the filesystem collector reports
one line for `/` while missing every other mount.

`/sys` keeps its own name inside the container rather than living under `/host`, because
cAdvisor has no path-prefix option: it always reads `/sys/fs/cgroup`.

### Cardinality is the thing to get wrong here

cAdvisor's `store_container_labels` exports **every** Docker label as a metric label, and
compose sets several — including the config hash, which changes on every deploy and would
orphan a whole set of series each time. It is off, and an allow-list keeps the two labels
that identify a container:

| From | To | Why |
|---|---|---|
| `container_label_com_docker_compose_service` | `service` | **The same label the logs carry.** This is what lets a dashboard put a service's CPU next to its error rate without a join. |
| `container_label_com_docker_compose_project` | `project` | Tells the application apart from this stack, and from anything else on the host |

Both long labels are then dropped. `docker_only = true` also keeps systemd's own slices out,
which would otherwise double every number under a second set of series.

### Metrics are NOT filtered to the project, and logs are

A deliberate asymmetry. For **logs**, content is application-specific and noise costs index
and disk, so only the `greener` project is collected. For **resources**, you want the whole
machine or the numbers do not add up — a host at 90% CPU because of something outside the
project is exactly what you need to see. The services dashboard has a `project` variable to
narrow it down.

### Telling an empty metrics stack from a broken one

A healthy datasource proves the store answers, not that anything is in it: with the
exporters misconfigured, Prometheus stays perfectly happy and every panel is empty. So the
role probes for series that only exist if each exporter really ran
(`monitoring_metrics_probes`), and a deploy that cannot produce them **fails**:

| Probe | Proves |
|---|---|
| `node_uname_info` | the node exporter ran and read the host |
| `up{job="integrations/cadvisor"}` | Alloy scraped the cAdvisor exporter |
| `count(container_last_seen{project="greener"}) >= <n>` | cAdvisor actually read the containers |

The third one exists because the first two passed while the metrics stack was blind: `up`
proves the exporter *answered*, never that it found anything. It counts against
`monitoring_alert_expected_containers`, the same list the container-down rules iterate, so
the assertion and the alerts cannot drift apart.

All of them go through Grafana's datasource proxy, because Prometheus publishes no host
port.

### Retention

15 days of metrics against 7 of logs. Metrics are far cheaper per unit of time and they are
what answers "was it slow last week too". The disk is the limit — this is the second
variable to check after the Loki retention.

## Separate compose project

This stack lives in `/opt/greener-monitoring`, **not** `/opt/greener`. Two compose projects
in one directory would fight over `docker-compose.yml`, and more importantly a monitoring
change must never restart the application (nor the reverse).

The network (`greener_monitoring`) is separate too, and it **stays** separate now that the
real container logs are collected — which was not the original plan. Collecting them looks
like it should need Alloy on `greener_internal`, but it does not: `loki.source.docker` asks
the **daemon** for a container's log stream over the socket. Nothing is fetched from the
containers themselves, so the collector needs no route to them, and the two projects still
share no network.

## Reaching Grafana

The container publishes on the loopback only. The shared `grafana_public` toggle in
`group_vars/all/vars.yml` decides whether **Caddy** additionally serves it at
`grafana.<caddy_domain>`; the role consumes the same answer for Grafana's root URL and for
the hardening below.

Either way the tunnel always works:

```bash
ssh -L 3000:127.0.0.1:3000 lboillot@<vps>
# then browse http://localhost:3000  (user: admin, password: vault_grafana_admin_password)
```

### The public vhost is ON, deliberately

`grafana_public: true` today — an **accepted risk**, not an oversight, recorded in
[SCRUM-133](https://greener-epitech.atlassian.net/browse/SCRUM-133). It stays on until
OpenVPN is configured ([SCRUM-58](https://greener-epitech.atlassian.net/browse/SCRUM-58)):
making seven people open a tunnel for every glance at a dashboard is not workable during
development.

What already protects it — verified, not assumed:

| | |
|---|---|
| Brute force | Grafana OSS blocks login 5 min after 5 failed attempts, **on by default** |
| Transport | the vhost imports `security_headers`: HSTS, `X-Frame-Options: DENY`, `nosniff`, no `Server` |
| Credentials | one vault password per person, 12 chars minimum enforced by an `assert`, no shared fallback |
| Signup | `GF_USERS_ALLOW_SIGN_UP: false`, no telemetry egress |
| Identities | synthetic `@greener.local` addresses, so no real address is exposed |

The toggle also renders three compensating settings — `cookie_secure`, `disable_gravatar`
and a 7-day session lifetime (`monitoring_grafana_session_lifetime`) — that are
deliberately **not** rendered when it is off. Their presence in the running config is the
signal that the exposure is still on.

**The residual risk none of this covers** is a Grafana CVE being reachable from the
internet. Only the network restriction fixes that, which is what makes
[SCRUM-58](https://greener-epitech.atlassian.net/browse/SCRUM-58) — the VPN, then Grafana
bound to its address and this variable deleted — the real answer rather than a
nice-to-have.

A basic-auth gate in Caddy was considered and dropped: it would shield Grafana even against
a CVE, but at the cost of a second credential to distribute to seven people. Reconsider it
if the VPN slips.

While on, the vhost needs a DNS record for `grafana.<caddy_domain>` or ACME cannot issue the
certificate. All four project subdomains already resolve to the VPS.

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

### The message is an embed, and that is what makes the links clickable

Grafana's default Discord message (`default.message`) prints, for every alert in the group,
its full label set, its annotations, and two bare URLs. It is accurate and nobody reads it.
What arrives now is three lines:

```
🔴 Conteneur ai arrêté            <- embed title, red because the group is firing
Le conteneur ai ne tourne plus depuis 5m.
production · ai · critical
règle · silence · logs            <- three words, each a link
```

**`use_embed_description: true` is what makes that possible**, not the template. Grafana's
notifier normally puts `message` in the payload's top-level `content` and leaves the embed
with only a title — and Discord does **not** render masked links, `[word](url)`, in
`content`. It renders them in an embed description. Without the flag the same template
arrives as three naked URLs, which is worse than the default.

**The cost is real and it is silent**: Discord only delivers `@mention` notifications from
`content`. With the message inside the embed, an `@here` or `<@id>` in the template renders
as plain text and pings nobody. Nothing mentions anyone today; if that ever changes, the
mention has to move back into `content`, which means giving up the masked links.

Two more things the template leans on:

* The status is carried by the embed **colour** (red firing, green resolved), so the message
  does not spell out `[FIRING]`. The emoji is there for the one distinction colour cannot
  make: warning versus critical.
* `summary` is ranged over per alert rather than read from `.CommonAnnotations`. An
  annotation only lands in `CommonAnnotations` when it is byte-identical across the whole
  group — and four rules now template their **measured value** into the summary, so the
  common one is empty and reading it would leave the message with no sentence at all.

The `logs` link is a deep link into the `greener-logs` dashboard with the service
pre-selected, which only works because the metric label and the log label are both called
`service` and hold the same value. It is skipped for host rules (`service: host`), which
have no log stream.

### What an alert does NOT tell you

Deliberately. The remediation for the two host rules lives here rather than in every
message:

* **Disque presque plein** — look at the Loki retention (`monitoring_loki_retention`) and
  the Prometheus retention (`monitoring_prometheus_retention`) first, then container logs.
  The host is a 77 GB disk sitting around 77% in normal operation, so the margin is thin by
  design and this rule is the one most likely to be the monitoring stack's own fault.
* **Mémoire presque saturée** — the AI service is the consumer that matters; check it on the
  services dashboard before assuming a leak elsewhere.

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

Two datasources now: Loki for what the services *say*, Prometheus for what they *do*.

| Rule | Datasource | Fires when | `noDataState` | State |
|---|---|---|---|---|
| `greener-error-rate` | Loki | more than `monitoring_alert_error_threshold` error lines per service in the window | `OK` | active |
| `greener-disk-low` | Prometheus | the root filesystem passes `monitoring_alert_disk_threshold`% | `OK` | active |
| `greener-memory-high` | Prometheus | less than 10% of RAM available, cache excluded | `OK` | active |
| `greener-container-down-<service>` | Prometheus | an expected container stops running | `OK` | active |
| `greener-restart-loop` | Prometheus | any project container starts more than `monitoring_alert_restart_threshold` times in `monitoring_alert_restart_window` | `OK` | active |
| `greener-unhealthy-<service>` | Prometheus | a service that declares a healthcheck fails it past its grace period | `OK` | active |
| `greener-silent-<service>` | Loki | a watched service stops logging | `Alerting` | **deleted by SCRUM-129** |

### The summaries carry the measured value

`{{ $values.A.Value }}` is the number query `A` returned **for that instance**, so the
message says `Le disque racine est à 92.0 % d'occupation (seuil 85 %)` rather than
repeating the threshold back at you. It works the same on Loki — `15 erreurs en 5m sur ce
service (seuil 10)`.

This is what makes each alert's summary different from its neighbour's, which is exactly
why the contact point ranges over `.Alerts` instead of reading `.CommonAnnotations`. The
two changes only work together.

### Proving a rule change before it reaches the channel

A rule that provisions cleanly can still be wrong, and the channel is a bad place to find
out. The whole chain runs locally: a Python script serving a `/metrics` file with the
numbers you want, `prom/prometheus` scraping it, `grafana/grafana` at the pinned version
with the **rendered** provisioning files, and the webhook pointed at a listener that dumps
the JSON Discord would have received.

Render the templates with the real defaults, override the `for` delays to `0s` so a run
takes a minute instead of twenty-five, and read the captured payload. Every rule in the
table above was checked that way, including its rendered summary, its emoji and its links.
It is also how the `.ExternalURL` double slash and the resolved message repeating a
problem in the present tense were caught — neither is visible from the YAML.

### The restart loop is the one nothing else catches

A container that dies and comes back every minute is `running` most of the time. It never
fills the 5-minute `for` of `greener-container-down-*`, and the external probe (SCRUM-90)
sees a facade that answers between two deaths — so without this rule, a crash loop is
invisible to the whole stack.

It counts restarts as `changes()` on `container_start_time_seconds`, and there is a nice
property hidden in that choice: **a deploy does not trip it**. A compose recreate gives the
container a new id, so cAdvisor opens a fresh series whose start time has never changed.
Only a restart *in place* moves the value of an existing series — which is exactly what a
crash loop is, and nothing else on this host does it.

This is the one rule that is **not** written per service. The others are, because a series
that has vanished cannot be grouped over; here the container is running and the series
exists, so a single rule with `max by (service, env)` yields one instance per service.
Its `service` label therefore comes from the query, and the rule must NOT set a static one
— that would flatten every service onto a single alert.

### `container_health_state` cannot tell "no probe" from "broken"

cAdvisor encodes it `1` healthy, `0` starting **or** unhealthy, `-1` no healthcheck
declared. Two things follow, both found against production rather than reasoned about:

**The gateway declares no healthcheck and this build reports it as `0`, not `-1`.** So on
this stack a naive `== 0` rule fires for ever on a container that is perfectly fine. That
is why `monitoring_alert_healthcheck_grace` is a **map of the services that really declare
a probe** rather than the expected-containers list. Adding a healthcheck to a service means
adding it here; removing one means removing it here, or its rule alerts for ever.

**"Starting" also reads as `0`,** so each grace period has to outlast that service's
`start_period` in `app_stack`. They are not uniform for a reason:

| Service | `start_period` | `for` |
|---|---|---|
| `postgres` | 10s | 5m |
| `backend` | 15s | 5m |
| `qdrant` | 30s | 5m |
| `ai` | **20m** — it indexes every region before uvicorn answers | **25m** |

A uniform five minutes would page on every single AI restart, which is the kind of rule
people learn to ignore. The threshold is `within_range [-0.5, 0.5]` and not `lt 1`
precisely so that `-1` is excluded: "nobody is checking" is not "it is broken".

### Tuning the error rate on real traffic

The threshold (10 errors per 5 min per service) was a guess made while the only producer
was a generator. It now runs on real logs, so it is the number most likely to need
retuning — watch the dashboard's error panel for a week before trusting it.

What it catches first is the **gateway**: nginx logs a missing `favicon.ico` at `[error]`,
so a crawler alone can produce a handful per minute. That is the rule working, not
misfiring, and the fix is to stop serving those 404s — not to raise the threshold
reflexively.

To exercise the whole path on demand, deploy once with
`-e monitoring_alert_error_threshold=0`.

### Why the silence rules are gone

They were the provisional "service is down" proxy, and they rested on an assumption that
died with the synthetic log generator they were built against: **that silence means
death**. That only holds for a source which logs unconditionally. The generator did — a
few lines per service per minute, whatever happened. The real services do not: a FastAPI
backend logs on request, so at 03:00 with no users it emits nothing, and the rule would
have paged for a service in perfect health. Caddy and the AI service behave the same way,
and Postgres is near-silent at rest.

Production confirmed it before a single alert was written: four of the five containers had
produced no log line for over an hour while being entirely healthy, simply because nothing
had asked them to do anything.

A pager that cries at 03:00 for a healthy service is worse than no pager at all — it
teaches the team to ignore the channel. `greener-container-down-*` replaced them, on
metrics rather than chatter.

**How they were retired, which is the part worth copying.** They were switched off, the
uid teardown deleted them from Grafana, the host and the Grafana API were both checked to
be clean, and only then was their code removed along with the generator's. In that order,
always: a provisioned rule whose file merely disappears keeps evaluating forever, so
deleting the code first would have left four rules notifying with nothing in the
repository to explain them.

### What actually detects a dead service

`greener-container-down-<service>`, since SCRUM-99 — and it works for the reason the log
rules could not: **cAdvisor emits series for a container as long as it runs**, whatever the
container says or does not say. Absence is death, not a quiet night.

**Read the states backwards on that rule.** `absent()` returns `1` when the series is
*missing* and nothing at all when it is present, so the healthy case is `NoData` — which is
why `noDataState: OK` is correct here and was the exact opposite on the rules it replaces.
The labels are static for the same reason as before: `absent()` returns a series with no
labels, so without them the Discord message could not name the service that died.

The expected list is the real one this time:

```yaml
monitoring_alert_expected_containers: [gateway, backend, ai, postgres, qdrant]
```

The failure mode to know about: `absent()` cannot distinguish "this container is dead" from
"cAdvisor never saw it", so a **blind collector fires every one of these rules at once**.
That is what happened on the first production run (see the containerd trap above). Five
container-down alerts together mean the exporter, not the application; one dead container
fires exactly one rule.

Docker's own healthchecks (defined in `app_stack` for `backend`, `postgres`, `qdrant` and
`ai`) are a finer signal still — a container can run while failing its probe. This cAdvisor
version does export `container_health_state`, so the data is within reach, but no rule or
panel uses it yet.

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

## Running it

```bash
make check ENV=production                                   # dry run, whole playbook
ansible-playbook -i inventories/production/hosts.yml site.yml --tags monitoring
```

On the host:

```bash
docker compose -f /opt/greener-monitoring/docker-compose.yml ps

# What Alloy decided to collect, and what it rejected — the first thing to look at when a
# service is missing from the dashboard.
docker logs greener-monitoring-alloy-1 --tail 50

# Which streams actually exist in Loki (the answer the dashboard variables read):
docker exec greener-monitoring-grafana-1 \
  wget -qO- 'http://loki:3100/loki/api/v1/label/service/values'
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
- Labels are kept to `service`, `level`, `env`, `source` and `agent` — about 30 streams in
  practice. Every label combination is a separate Loki stream, so a high-cardinality label
  (request id, status code, duration) would blow up the index. Everything else stays in the
  log line and is queried with `| json` or `| pattern` at read time, which is exactly what
  Loki is good at.
- `reject_old_samples` is on, which is the other reason nothing parses timestamps out of
  the log lines: a line stamped outside the retention window is dropped, silently.
