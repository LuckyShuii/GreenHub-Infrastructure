# webhook role

The **CD receiver**: the [adnanh/webhook](https://github.com/adnanh/webhook) daemon that the
CI calls once it has published an image, plus everything the VPS needs to deploy *itself*.

```
GitHub Actions ──POST /hooks/deploy-<service>──▶ Caddy (443, TLS)
                  X-Deploy-Token + {"version"}        │
                                                      ▼  127.0.0.1:9000
                                             webhook daemon (user: deploy)
                                                      │ token + version match
                                                      ▼
                                             greener-deploy <service> <version>
                                                      │ flock
                                                      ▼
                                             ansible-playbook deploy.yml  (connection: local)
                                                      │
                                                      ▼
                                             docker compose pull + up -d --wait
```

## The contract with the CI

| | |
|---|---|
| Endpoint | `POST https://deploy.<domain>/hooks/deploy-backend` \| `/hooks/deploy-ia` |
| Auth | header `X-Deploy-Token`, the value the pipeline holds as its `VPS_DEPLOY_KEY` repo secret |
| Body | `{"version": "<commit sha>"}` or `{"version": "latest"}`, `Content-Type: application/json` |
| Refused | `403`, and **nothing is executed** (`trigger-rule-mismatch-http-response-code`) |

`VPS_DEPLOY_KEY` is an **HTTP token, not an SSH key** — the CI never opens an SSH session to
the VPS. It lives in the env vault as `vault_deploy_webhook_token` and must be given to the
backend and AI repos as a GitHub secret with the same value:

```bash
ansible-vault view inventories/production/group_vars/all/vault.yml   # read it
openssl rand -hex 32                                                 # rotate it
```

It is a different secret from the registry **pull** token, which never leaves the vault.

The daemon answers **as soon as the rules match**, before the deploy finishes
(`include-command-output-in-response: false`) — a long AI bring-up would otherwise time out
any `curl`. So a `2xx` means *the trigger was accepted*, not *the deploy succeeded*; the
outcome is in the journal (see below).

## Why the deploy runs locally

Provisioning stays a **push** run from a workstation (`site.yml`). Only the recurring deploy
runs **on the VPS**, in local connection, as `deploy` — the CI has no SSH access and should
not have any. That model needs three things on the host, all set up by this role:

1. `ansible-core`, from APT.
2. A copy of the deploy playbook, the roles it uses (`app_stack`, `backend`), the shared
   `group_vars/` and this environment's `group_vars` under `/opt/greener/ansible`, owned by
   `deploy` — **pushed by the provisioning run**, not cloned. No GitHub deploy key to manage
   and no network dependency on GitHub when a deploy fires. The flip side: a change to
   `deploy.yml` or to those roles only reaches the VPS at the next `make deploy`.
3. The ansible-vault passphrase at `/etc/greener/vault_pass`, `0400` and owned by `deploy`,
   copied from the same file `ansible.cfg` points at on the control host. Rekey there, replay,
   and the VPS follows.

The vaulted files are shipped with `decrypt: false` so they stay **encrypted at rest** on the
VPS — without it Ansible would helpfully decrypt them in transit and write the secrets in clear.

## Least privilege

The daemon runs as `deploy`: a nologin, non-human account declared in
`group_vars/all/users.yml`, with **no sudo at all**. It can deploy because everything it
rewrites under `/opt/greener` is owned by it and because it reaches docker through its group
membership — not because it can become root. Its registry credentials come from the login the
`docker` role performs for that same account.

The daemon listens on `127.0.0.1` only. Caddy is the sole host-facing service, as everywhere
else here.

## Concurrency

The backend and AI pipelines can fire at the same time, and two concurrent compose runs on the
same project fight over the same containers. `greener-deploy` therefore serialises everything
through `flock` on `webhook_lock_file`; a deploy that cannot take the lock within
`webhook_lock_timeout` gives up with exit 75 rather than queueing forever.

## Reading the trail

Everything the daemon and the playbook print goes to the journal:

```bash
journalctl -u greener-webhook -f            # live
journalctl -u greener-webhook --since -1h   # what happened
cat /opt/greener/deployed-versions.yml      # what is running right now
```

`deployed-versions.yml` is written by the `app_stack` role after every successful bring-up and
is what makes a targeted redeploy safe: rolling one service re-renders the compose file with
the tag the *other* service is recorded as running, instead of resetting it to a default.

## Rolling back

Not automated in this version. Pin the previous tag from the control host:

```bash
ansible-playbook -i inventories/production/hosts.yml site.yml --tags app_stack \
  -e app_stack_enabled=true -e app_stack_backend_version=<previous-sha>
```

The record file is updated by that run too, so the next webhook deploy of the *other* service
will not undo it.

## Notes

- The Debian package ships its own `webhook.service`, listening on every interface with its own
  `/etc/webhook.conf`. It is stopped, disabled and **masked** here; we run `greener-webhook`
  instead, so a package upgrade can never take the config over.
- `hooks.json` is `0640 root:deploy` and holds the token, so it is rendered with
  `no_log` / `diff: false` like every other secret-bearing template here.
- The collections are installed on the host from the same pinned `requirements.yml` as the
  control host, so a local run behaves like a push run.
