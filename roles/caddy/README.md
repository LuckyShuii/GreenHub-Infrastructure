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
