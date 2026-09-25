# `backups` role

**Encrypted PostgreSQL dumps, on a systemd timer, reported as Prometheus metrics.**

Dumps the `greener` database every 3 hours, compresses and encrypts each dump, and writes
four metrics where the node exporter's textfile collector picks them up. Rotation
(SCRUM-77), off-site replication (SCRUM-78/79) and restore drills (SCRUM-80) are separate
tickets and are deliberately not here — this role only guarantees that a good dump exists
and that its absence is visible.

## The chain

```
docker exec postgres pg_dump | gzip -9 | gpg --symmetric AES256 > greener_<stamp>.sql.gz.gpg
```

**`pg_dump` runs inside the container.** The database publishes no port and the host has no
PostgreSQL client, so the dump goes through `docker exec` and the container's local socket.
Two things fall out of that for free: the client version always matches the server, and no
database credential ever has to reach the host — `POSTGRES_USER` and `POSTGRES_DB` are read
from the environment the container already has.

The container is located by its **compose labels**, never by name: compose derives container
names from the project directory, so a hardcoded name breaks the day `/opt/greener` moves.

**`set -o pipefail` is the point of the script, not a detail.** Without it bash reports only
`gpg`'s status, so a `pg_dump` that dies mid-stream yields a perfectly valid `.sql.gz.gpg`
holding half a database — and exits 0. Three things guard against that, and they are all
there for the same reason:

- `pipefail`, so a failure anywhere in the pipe is a failure;
- a **size floor** (`backups_min_size_bytes`), because a truncated pipe can still produce a
  well-formed tiny file;
- an **atomic rename**: the dump is built as `…​.partial` and only renamed once it has passed
  the size check, so a partial file never exists under the final name. The off-site sync
  copies whatever it finds in this directory, and a truncated file that reached Drive would
  look exactly like a good one.

## Who can read a dump

`/var/backups/db-postgres/greener` is **root:greener, mode 2750**, and the files inside are
**0640**. Three pieces have to agree for that to actually hold:

- the **setgid bit** (the leading `2`) — without it the dumps are created by root and land in
  the root group whatever the directory says, so the group would be pure decoration;
- `umask 027` in the script, since `gpg --output` obeys the umask like anything else. The
  inherited 022 left the first production dumps world-readable (0644) — harmless while the
  directory was 0700, wrong the moment a file is copied somewhere else, which is exactly
  what the off-site sync will do;
- the metrics file is chmod'd back to 0644 explicitly, because the exporter has to read it.

Setgid only governs files created after it is set, so the role also normalises any dump
written before it owned the mode. That is a task rather than a one-off `chmod` on the server
on purpose: the repository's rule is that the replay, not a person, puts the host right.

**Accepted:** every member of the `greener` group — sudo or not, which today is the whole
team — can read the encrypted dumps. They stay useless without the GPG passphrase, which
remains 0600 root. The parent `/var/backups/db-postgres` is not group-readable; only the
leaf is.

The script does **not** create that directory. Ansible owns it, and an `install -d -m …`
would quietly reset the mode on every run; a missing directory is an upstream problem worth
failing on rather than papering over.

## Encryption

Symmetric AES256, passphrase from `backup_gpg_passphrase` (a `vault_*` value), rendered by
Ansible into a 0600 file. The task that writes it sets `diff: false` and `no_log` for the
same reason as the backend `.env`: the passphrase must not surface in `--check --diff` or in
a verbose failure. Debug locally with `-e hide_secrets=false`, never in CI.

`--pinentry-mode loopback` is mandatory rather than defensive: without it gpg 2.x ignores
`--passphrase-file` entirely and tries to open a pinentry prompt, which under a systemd
service fails with no useful message. The role also gives gpg its own `GNUPGHOME`, because
root's may not exist on a fresh host and gpg needs somewhere for its random state even for a
symmetric encryption that touches no keyring.

> **The vault is the only copy of that passphrase.** Losing the repository and the vault
> passphrase together makes every dump unreadable, local and off-site alike. Keeping a copy
> outside git is part of the DRP, not of this role.

## Scheduling

A systemd **timer**, not cron — the same pattern as the container-health collector. Three
reasons, in order of how much they matter here:

1. systemd will not start a unit that is already running, so a dump that overruns its slot
   is never doubled by the next tick. With cron that needs an explicit lock.
2. The job's output goes to journald, which Alloy already ships to Loki. A cron job would
   need its own log file, and that file would never reach Grafana.
3. `OnBootSec=` fires after each boot and `Persistent=true` catches up an occurrence the
   host slept through — together they close the gap the RPO target cares about.

`OnBootSec=` is not redundant with `Persistent=`, and the difference bit us on the first
deploy: `Persistent=` only replays occurrences it can *prove* were missed, and a first
install has no stamp file to prove anything with, so the timer sat idle until the next slot
(`LAST` empty, three hours away) — no backup and, worse, no metrics at all, which drops
`greener-backup-stale` straight into its no-data alert. On a host booted long ago
`OnBootSec=` is already overdue, so activating the timer fires the first dump at once.

The role runs **after `app_stack`** in `site.yml`, out of alphabetical order: that first
dump fires during the deploy, so Postgres has to be up before the timer is enabled.

## What it reports

Four gauges in `db_backup.prom`. Three of them describe the last **successful** dump and are
read back from a small state file; only the exit code describes the run that just happened:

| Metric | Describes |
| --- | --- |
| `greener_backup_last_success_timestamp_seconds` | when the last good dump completed |
| `greener_backup_last_duration_seconds` | how long it took |
| `greener_backup_last_size_bytes` | how big it was, encrypted |
| `greener_backup_last_exit_code` | the most recent attempt, successful or not |

That split is deliberate: a failed run must report its failure **without** erasing the
evidence of when the last good backup was — and that timestamp is the value the alert reads.

Two rules watch them (group `greener-backups`, in the monitoring role). The one that matters
is **staleness**, not failure: a script only reports an error when it runs, and the failure
that actually loses a database is the timer that quietly stopped firing. Age of the last
success is the only signal that sees both. The threshold is 7 h — two missed occurrences of
a 3-hourly dump — so one skipped slot does not page anyone.

## Coupling to the monitoring role

Two values are duplicated rather than imported, because a role must not depend on another
role's defaults being in scope (the same rule `monitoring_app_compose_project` follows):

- `backups_textfile_dir` must match `monitoring_container_health_dir`'s parent;
- `backups_pg_compose_project` must match `app_stack`'s compose project.

Both roles create the textfile directory, since on a fresh host they can run in either order
and the first timer tick has to have somewhere to write.

## Variables

See `defaults/main.yml`. The ones worth knowing: `backups_enabled` (deploys the script and
units either way, only gates starting the timer), `backups_on_calendar`, `backups_dir`,
`backups_min_size_bytes`.

Holds no secret of its own — the passphrase comes from the vault through
`backup_gpg_passphrase`.
