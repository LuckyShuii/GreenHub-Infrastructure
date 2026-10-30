# Role `openvpn`

OpenVPN server with its **own certificate authority**, so the internal services reach the
team without being exposed on the Internet. UDP 1194, AES-256-GCM, TLS 1.2 minimum,
`tls-crypt` on the control channel, split tunnel.

## The PKI stays on the host

The CA private key is generated on the VPS and never leaves it. That is a deliberate
departure from the rest of the repo, where every secret is an ansible-vault file in git:
a **signing** key is a different class of secret from a password. Encrypted in git it would
still be one `git clone` plus one vault passphrase away from minting a certificate for the
whole fleet, and every laptop with a checkout would be holding it.

What the vault holds instead is the **passphrase** protecting that key
(`vault_openvpn_ca_passphrase`, re-exposed as `openvpn_ca_passphrase`). Ansible hands it to
easy-rsa in the environment of the signing commands only, which means it is readable in
`/proc` for the length of a signature by someone already running code on the host. The
alternative — a passphrase file sitting next to the key it protects — would be stolen in the
same breath as the key, so the transient exposure is the better of the two.

Consequence worth stating plainly: **the CA lives only on the VPS**. A lost host means a new
CA and new profiles for everyone. That is acceptable because nothing else depends on this CA,
and re-issuing seven certificates costs one replay — but it is a conscious choice, not an
oversight. Add the PKI to the backup scope the day that stops being true.

## Clients come from `users.yml`

There is no "add a VPN user" command. The client list is derived from `system_users`, the
same declarative source of truth as the system accounts:

```yaml
- name: ecouy
  state: present
  groups: [greener, docker]
  grafana: Editor
  vpn: true          # <- issues a certificate; omit it to issue none
```

So an **offboarding stays one PR**: flip `state: absent`, merge, `make deploy`. The same
replay removes the system account and revokes the VPN certificate. A certificate found in
the PKI that no account asks for any more is revoked too — including one issued by hand
outside this role.

Three rules the role enforces on itself:

- **Nothing is ever re-issued.** Every creation step is guarded on the file it produces, so a
  replay cannot quietly invalidate a `.ovpn` already in someone's hands.
- **The server's own certificate is never revoked**, whatever the account list says — that
  would take the VPN down with it.
- **A revocation restarts the daemon.** The CRL stops a revoked client from reconnecting but
  does nothing to a session already established, and cutting it is the point. The cost is
  that every connected member is dropped for the ~2 s of the restart and reconnects on their
  own. A management socket to kill one session by name is the cleaner answer the day that
  trade stops being acceptable.

## Delivering and revoking a profile

Profiles are assembled **on the host** by `/usr/local/sbin/greener-vpn-profile`, so a client
private key never crosses the network to the controller. They sit in
`/etc/openvpn/clients/<name>.ovpn`, 0600 root.

The script rebuilds a profile when its **content** would change — the shared options moved, a
certificate was re-issued, the `tls-crypt` key was rotated — and reports `unchanged`
otherwise, so a replay is idempotent. Comparing mtimes instead would not work: on a first run
the shared options and the profile are written in the same second.

```bash
# issue everything users.yml asks for (part of a normal replay)
make deploy ENV=production ARGS="--tags openvpn"

# then, deliberately, bring the profiles back to the operator's machine
make vpn-profiles ENV=production
```

Delivery is its **own playbook** (`vpn-profiles.yml` → `tasks/fetch.yml`), not a tagged task
in this role, and that is not a style choice. A role-level tag is inherited by every task in
the role, so `tags: [never]` on a fetch task does **not** hold against `--tags openvpn`: the
profiles came down on a plain provisioning run. A separate playbook cannot be reached by a
replay at all.

It writes into `vpn-clients/` (gitignored), directory 0700 and files 0600 — `fetch` accepts
`mode:` and silently ignores it, so the mode is set in a following task. **A `.ovpn` holds the
client's private key**: hand it over through a channel you would use for a password, never by
email to a list.

Revoking is the same single edit:

```yaml
- name: someone
  state: absent     # ← the next replay revokes the certificate and restarts the daemon
```

## Split tunnel, and what the VPN actually reaches

No `push redirect-gateway` and no pushed DNS: a connected member keeps their own default
route, and only `10.8.0.0/24` goes through the tunnel. Nothing is forwarded or NATed either —
the server is a destination, not a gateway.

That is enough, because everything this VPN exists for is on this host. But be precise about
what "reach the internal services" means here (decision LBT, 2026-10-24):

| service | over the VPN |
|---|---|
| SSH | `10.8.0.1:22` — it listens on every interface |
| Grafana | `10.8.0.1:3000` — the monitoring role publishes it on the VPN address |
| PostgreSQL | **not directly**: it publishes no host port at all |

Grafana being on the VPN address is what let `grafana_public` be turned off. Publishing on
`0.0.0.0` is never an option here: Docker bypasses UFW, so that would put it on the Internet.

A container can only bind an address that exists, and after a reboot dockerd starts before
the tunnel is up — so this role sets `net.ipv4.ip_nonlocal_bind`, without which Grafana's
bind fails on boot and it never comes back.

PostgreSQL publishes no host port at all, by design. Reach it through the container:

```bash
ssh <account>@10.8.0.1
docker compose -f /opt/greener/docker-compose.yml exec postgres psql -U greener
```

## The CRL expiry trap

**An expired CRL makes OpenVPN refuse every connection, revoked or not.** The list is
regenerated only when it is missing or after a revocation, so its window is set long on
purpose (`openvpn_crl_days`, 10 years). If you shorten it, something has to regenerate it
before it lapses, or the VPN dies on a date nobody wrote down.

The daemon reads `/etc/openvpn/server/crl.pem`, a copy, not the PKI's original: it re-reads
the file after dropping privileges to `nobody`, which cannot enter the 0700 PKI directory. A
revocation list is public by design — it says which certificates are dead, nothing more.

## Why it runs before `firewall`

`site.yml` runs this role **before** `firewall`, out of alphabetical order. The firewall
refuses to restrict SSH to the VPN while the VPN interface is missing (a guard against
locking everyone out), and this role is what creates `tun0`. Running it first is what makes
the switch in [`docs/firewall.md`](../../docs/firewall.md) §3 a single replay.

The role also re-gathers the network facts once the service is up, because facts collected at
the start of the play predate `tun0` and the firewall's guard would read a stale interface
list. `openvpn_interface` and `firewall_vpn_interface` must stay in step; the role asserts it
rather than trusting it.

## Reading a run

```bash
systemctl status openvpn-server@greener
journalctl -u openvpn-server@greener -n 50      # who connected, who was refused
cat /run/openvpn-server/status-greener.log      # currently connected clients
```

There is no `log` directive in the configuration on purpose: output goes to the journal,
Alloy collects it, and the connection trail is queryable in Grafana like everything else.

## Variables (`defaults/main.yml`)

| var | meaning |
|---|---|
| `openvpn_enabled` | start the service (the PKI and configuration are deployed either way) |
| `openvpn_instance` | systemd instance name, i.e. `openvpn-server@<name>` |
| `openvpn_interface` | VPN interface, pinned — must equal `firewall_vpn_interface` |
| `openvpn_subnet` / `openvpn_netmask` | VPN subnet; the server takes its first address |
| `openvpn_remote_host` | **public** address the clients dial, not `ansible_host` |
| `openvpn_easyrsa_*` | key algorithm, curve, digest |
| `openvpn_easyrsa_timeout` | wall-clock bound on `build-ca`, which can still decide to prompt |
| `openvpn_*_expire_days`, `openvpn_crl_days` | CA, certificate and CRL lifetimes |
| `openvpn_fetch_dir` | where `make vpn-profiles` drops the profiles locally (gitignored) |

> Holds no secret itself. Consumes `openvpn_ca_passphrase` from the vault.
