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
5. `docker` service enabled + started.

## Variables (`defaults/main.yml`)

| var                   | meaning                                                        |
|-----------------------|---------------------------------------------------------------|
| `docker_apt_prereqs`  | packages needed to fetch the key/repo                         |
| `docker_packages`     | Docker packages to install                                    |
| `docker_keyring_path` | armored GPG key location                                      |
| `docker_gpg_url`      | Docker GPG key URL (distro auto-detected)                     |
| `docker_managed_users`| **non-human** service accounts to add to the `docker` group; empty by default |

> No human is ever added to the `docker` group — that grants root-equivalent access.
> Humans use `sudo`; `docker_managed_users` is reserved for a future CI/service account.
> Holds no secrets.
