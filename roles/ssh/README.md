# `ssh` role

**SSH service hardening (intended to be reachable via VPN only, once OpenVPN is deployed).**

Renders a full `/etc/ssh/sshd_config` (validated with `sshd -t` before it is
written) and reloads `ssh` on change.

## Policy

- `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`
- Public keys only (`AuthenticationMethods publickey`): Ed25519 (incl. FIDO `sk-`)
  or RSA with SHA-2 signatures, RSA keys at least 4096 bits (`RequiredRSASize`)
- `MaxAuthTries 3`, `LoginGraceTime 30`, no X11 forwarding, no tunnels

## Variables

| var                     | default | meaning                                                        |
|-------------------------|---------|----------------------------------------------------------------|
| `ssh_port`              | `22`    | listening port                                                 |
| `ssh_required_rsa_size` | `4096`  | minimum RSA key size                                           |
| `ssh_enforce_rsa_size`  | `true`  | emit `RequiredRSASize` (needs OpenSSH ≥ 9.1: noble/bookworm, not jammy) |

## Ordering

Must run **after** `common`: accounts and their keys have to be in place before
password/root logins are disabled, otherwise a fresh VPS locks everyone out.
