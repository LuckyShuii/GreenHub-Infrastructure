# Role `maintenance`

Keeps the root filesystem from filling up. Upkeep only — it **acts** on the disk and
watches nothing: disk usage is a Node Exporter metric with its own alert rule, not a cron
notifying a chat. Three mechanisms, all declarative:

- **`greener-docker-prune`** — a systemd oneshot on a weekly timer that runs
  `docker image prune -f` and `docker builder prune -f --filter until=…`.
- **A journald drop-in** that caps the binary system journal.
- **logrotate**, asserted present with the distro's own rules, for the text logs
  under `/var/log`.

Container logs are the fourth piece and live in the `docker` role: the `json-file` driver
rotates nothing by default, so `max-size`/`max-file` are set daemon-wide there and pinned
per service in the compose files. That bounded driver is also what Alloy's Docker log
discovery assumes.

## Why a conservative prune

`docker image prune -a` (or `docker system prune -a`) removes every image no **running**
container uses. On this host that includes the ~12 GB AI image whenever its container is
stopped, which would turn a cleanup into a 12 GB re-pull. The prune here only removes:

- **untagged images** — what a deploy leaves behind when a `*-latest` tag moves to a new
  image. This is the single biggest producer of garbage on the host: one AI deploy orphans
  ~12 GB.
- **build cache older than the retention window**. Nothing in this repo builds on the VPS
  (every compose service pulls a published image), so this only ever reclaims cache left by
  something built on the host by hand.

Neither can remove an image a container still references, running or stopped.

A prune also runs at the end of `deploy.yml`, right where the orphan is created. The timer
is the safety net, not the primary mechanism.

## Rollback after a prune

Pruning untagged images removes the *previous* image of a service. Rolling back is a
re-pull by commit SHA (`deploy_version=<sha>`), not a local retag — CI publishes every
build under its SHA, so nothing is lost, it just costs a pull.

## Journal size, and what logrotate still does

Two different log stores, two different tools, no overlap: journald owns the binary journal
under `/var/log/journal` and is bounded by the drop-in below; logrotate owns the text files
under `/var/log` (`dpkg`, `ufw`, `auth` where rsyslog writes one) and keeps the rules its
own packages ship. This role only makes sure logrotate and its timer are installed —
a minimal image does not always carry them, and nothing else in this repo does it.

The journal is the half worth bounding explicitly, because systemd's default is 10 % of the
filesystem — 7.7 GB on a 77 GB disk, a lot of room to fill before anyone notices. Alloy ships the journal to Loki, which has its own
retention, so the local copy only has to cover what you would read before opening Grafana.

Changing `maintenance_journal_max_use` trims an over-sized journal on the next replay: the
handler restarts journald, and journald enforces its limits at startup.

## Reading a run

```bash
systemctl list-timers greener-docker-prune.timer
journalctl -u greener-docker-prune -n 50
sudo systemctl start greener-docker-prune.service   # run it now
```

Each run logs what it reclaimed and what is left on `/`, and it says so at a **journald
priority**, not just in words:

| line | priority | means |
|---|---|---|
| `prune reclaimed N MiB, …` | info | the normal weekly run |
| `prune reclaimed N MiB, ABNORMAL (above …)` | warning | more than `maintenance_reclaim_warn_mib` came back at once |
| `prune FAILED (exit N) after Ns` | err | a `docker` command returned non-zero |

The script writes `<4>` / `<3>` prefixes, which journald reads off the line and turns into
the entry's level (hence `SyslogLevelPrefix=yes` in the unit); run by hand in a shell it
drops them and prints plain text. So `journalctl -p warning -u greener-docker-prune` is the
whole history of anything that went wrong, and because the unit is in
`monitoring_journal_units` the same lines reach Loki with a `level` label — a failed prune
is visible in Grafana without logging into the host.

**A large reclaim is a warning, not good news.** Nothing should orphan gigabytes between
two weekly runs: `deploy.yml` prunes its own leftovers right where they are created, so
anything substantial here accumulated outside the deploy path. The deploy run passes a
higher threshold of its own — reclaiming the ~12 GB AI image is exactly what it is there
for.
