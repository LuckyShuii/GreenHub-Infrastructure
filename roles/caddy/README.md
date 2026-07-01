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

## Key variables (see `defaults/main.yml`)

| Variable | Default | Notes |
| --- | --- | --- |
| `caddy_version` | `""` (latest stable) | Pin (e.g. `"2.8.4"`) for reproducible installs. |
| `caddy_domain` | `lucasboillot.fr` | Env-specific; set per env in `inventories/<env>/group_vars/all/vars.yml`. |
| `caddy_acme_staging` | `true` | **Staging by default** (Let's Encrypt rate limits). Flip to `false` for trusted prod certs. |
| `caddy_backend_upstream` | `127.0.0.1:8000` | Internal upstream. Caddy runs on the host, so reach containers via a **published** port, not a container name. May be absent — a `200` fallback is served. |

Holds **no secrets** (no vault).

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
