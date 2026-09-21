# `docker` role

**Docker Engine + CLI + containerd + Compose plugin.**

Installs Docker from Docker's **official APT repository** (never the distro's
`docker.io`), idempotently and declaratively:

1. APT prerequisites (`ca-certificates`, `curl`, `gnupg`).
2. Official Docker GPG key in `/etc/apt/keyrings/docker.asc` (fetched only if absent).
3. Docker APT source for the **detected** distribution + release + `dpkg` architecture
   (via facts — nothing hardcoded), then cache refresh.
4. Packages: `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`,
   `docker-compose-plugin`.
5. `/etc/docker/daemon.json` — container log rotation, see below.
6. `docker` service enabled + started.

## Container log rotation

Docker's `json-file` driver **rotates nothing by default**: a container's log grows until
the disk is full. With real services now logging (SCRUM-129) on a host already at 77% of
77 GB, that is a matter of weeks, not a theoretical risk.

The cap is set on the **daemon**, not per compose service, so it also covers the containers
this repo does not render — the monitoring stack, anything started by hand. One place, and
no way to forget a service.

| | |
|---|---|
| Cap | `max-size: 10m` × `max-file: 3` → at most **30 MB of live log per container** |
| What that buys | roughly a day of the busiest container |
| Where history lives | **Loki**, with its own retention — `docker logs` is only what you read before Grafana is open |

Three things are easy to get wrong here:

- **The daemon reads `log-opts` at container creation.** A reload applies them to
  containers created *afterwards*; the ones already running keep their unlimited setting
  until their next recreation (any deploy does it).
- **The handler reloads, it never restarts.** Restarting `dockerd` stops every container on
  the host — the application included — for a change that only affects future containers.
- **The template carries no `ansible_managed` header**, unlike every other file this repo
  renders. `dockerd` rejects any key it does not know, comment-shaped or not, and then
  refuses to start. Hence also the `validate:` on the template task: a malformed
  `daemon.json` is a daemon that will not come back, which on a fresh VPS means no Docker
  at all. Do not edit it on the host — it is rendered from this role.

## Variables (`defaults/main.yml`)

| var                   | meaning                                                        |
|-----------------------|---------------------------------------------------------------|
| `docker_apt_prereqs`  | packages needed to fetch the key/repo                         |
| `docker_packages`     | Docker packages to install                                    |
| `docker_keyring_path` | armored GPG key location                                      |
| `docker_gpg_url`      | Docker GPG key URL (distro auto-detected)                     |
| `docker_managed_users`| **non-human** service accounts to add to the `docker` group; empty by default |
| `docker_daemon_config`| path of the rendered daemon configuration                     |
| `docker_log_driver`   | logging driver for every container (`json-file`)               |
| `docker_log_max_size` | size at which a container log rotates                          |
| `docker_log_max_file` | rotated files kept per container                               |

> No human is ever added to the `docker` group — that grants root-equivalent access.
> Humans use `sudo`; `docker_managed_users` is reserved for a future CI/service account.
> Holds no secrets.
