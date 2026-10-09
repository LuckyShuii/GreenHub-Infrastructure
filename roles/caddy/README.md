# `caddy` role

**Caddy reverse proxy, installed natively (systemd) — automatic TLS (ACME), security headers.**

Caddy is the **only host-facing service**: it publishes `80` + `443` and reverse-proxies
straight to the app backends. No Nginx, no extra internal proxy. HTTPS certs are obtained
and renewed automatically via ACME (Let's Encrypt).

## What it does

- Installs Caddy from its **official APT repo** (pinned key + `deb822` source) — no `curl|sh`.
- Renders a templated `Caddyfile` to `/etc/caddy/Caddyfile` (validated with
  `caddy validate` before it lands).
- Enables + starts the `caddy` **systemd** service.
- Reloads Caddy **with zero downtime** (`systemctl reload caddy` → `caddy reload`) only when
  the Caddyfile changes — never a restart.

## The `/privacy` page

`https://greenhub.<domain>/privacy` is served by Caddy itself, never proxied. It is not
decoration: Google refuses to move an OAuth app out of *Testing* status without a reachable
homepage and privacy-policy URL, and an app left in Testing has its refresh token expired
every 7 days — which would stop the off-site backup sync dead, and silently. Hosting the page
here rather than on a third party keeps it on a domain we control and renew.

Three constraints when editing it:

- it is matched on the `greenhub.` host only, because `api.<domain>` belongs to the backend
  and shadowing a path there is a surprise waiting to happen;
- **no braces anywhere in the body.** Caddy reads `{...}` inside a quoted string as a
  placeholder, so a `<style>` block would break the parse. Inline `style=` attributes only;
- the matcher is a **named matcher in block form**, and has to be. `handle` takes at most
  ONE matcher argument, so `handle /privacy /privacy/` is a parse error (caught by
  `caddy validate`, which is why the role validates before writing); and the one-line
  `@name host …` form accepts a single matcher type, while this needs host AND path.

The `reverse_proxy` below it sits inside a bare `handle` for a related reason: a bare
`reverse_proxy` is its own route and matches every request, so it would answer on `/privacy`
too, named matcher or not.

The contact line comes from `caddy_privacy_contact`.

## Key variables (see `defaults/main.yml`)

| Variable | Default | Notes |
| --- | --- | --- |
| `caddy_version` | `""` (latest stable) | Pin (e.g. `"2.8.4"`) for reproducible installs. |
| `caddy_domain` | `lucasboillot.fr` | Env-specific; set per env in `inventories/<env>/group_vars/all/vars.yml`. |
| `caddy_acme_staging` | `true` | **Staging by default** (Let's Encrypt rate limits). Flip to `false` for trusted prod certs. |
| `caddy_backend_upstream` | `127.0.0.1:8000` | Internal upstream. Caddy runs on the host, so reach containers via a **published** port, not a container name. May be absent — a `200` fallback is served. |
| `caddy_repo_enabled` | `true` | Circuit breaker for the Cloudsmith APT repo. See below. |

Holds **no secrets** (no vault).

## When the Cloudsmith repo is down

Caddy's APT repo lives on Cloudsmith, and the Caddy project periodically exhausts its
bandwidth quota there; the repo then answers `402 Payment Required` for everyone
(`caddyserver/dist#114`, `#115`, `#142`). Because `apt-get update` exits non-zero when *any*
configured repo fails, this breaks **every** apt task on the host — the first casualty is
`common : Install base packages`, which has nothing to do with Caddy. The whole playbook
dies on its first task.

`caddy_repo_enabled: false` writes `Enabled: no` into the repo's `.sources` file: apt skips
it, the repo stays declared and versioned here, and the installed Caddy keeps running
untouched. Only installs and upgrades are suspended.

There is an ordering trap. This role cannot disable its own repo on a host where the repo is
still enabled, because `common` runs first and this role's own prereq task also runs
`apt-get update` — both die before reaching the repo task. Breaking out needs one targeted
replay that starts *at* the repo task:

```sh
# 1. Flip the repo, using this role's own task, skipping the apt tasks that would die first.
ansible-playbook -i inventories/<env>/hosts.yml site.yml \
  --tags caddy --start-at-task "Configure Caddy APT repository" \
  -e caddy_repo_enabled=false

# 2. apt is usable again — replay normally.
make deploy ENV=<env> -e caddy_repo_enabled=false
```

Once upstream recovers, just drop the flag: the default is `true`, so nothing has to be
un-done, and a forgotten `false` cannot outlive the outage.

A fresh host cannot install Caddy at all while the repo is down — that is the honest
failure, not something this flag can paper over.

## Verify

```sh
# Service up:
systemctl status caddy

# Rendered config is valid:
caddy validate --config /etc/caddy/Caddyfile

# Ports published on the host:
sudo ss -ltnp | grep -E ':80|:443'

# Idempotence: a second run must report changed=0:
make deploy ENV=production   # or: ansible-playbook -i inventories/production/hosts.yml site.yml

# Caddy answers on 443 (staging cert is untrusted, hence -k):
curl -kI https://greenhub.lucasboillot.fr/
```
