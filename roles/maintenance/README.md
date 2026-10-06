# Role `maintenance`

Keeps the root filesystem from filling up. Two mechanisms, both declarative:

- **`greener-docker-prune`** — a systemd oneshot on a weekly timer that runs
  `docker image prune -f` and `docker builder prune -f --filter until=…`.
- **A journald drop-in** that caps the system journal.

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

## Journal size

systemd's default is 10 % of the filesystem — 7.7 GB on a 77 GB disk, which is a lot of
room to fill before anyone notices. Alloy ships the journal to Loki, which has its own
retention, so the local copy only has to cover what you would read before opening Grafana.

Changing `maintenance_journal_max_use` trims an over-sized journal on the next replay: the
handler restarts journald, and journald enforces its limits at startup.

## Reading a run

```bash
systemctl list-timers greener-docker-prune.timer
journalctl -u greener-docker-prune -n 50
sudo systemctl start greener-docker-prune.service   # run it now
```

Each run logs what it reclaimed and what is left on `/`. The unit's exit code is what
matters on failure: Alloy collects the journal, so a failed prune is visible in Grafana
without logging into the host.
