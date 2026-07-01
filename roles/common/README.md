# `common` role

Baseline applied first on every host: base packages, timezone, the shared
`greener` group + setgid workspace, system accounts, and sudo rights.

## Users pattern (declarative)

Accounts are the single source of truth in `inventories/<env>/group_vars/all/users.yml`
as a `system_users` list. Each entry:

| key             | meaning                                              |
|-----------------|------------------------------------------------------|
| `name`          | account name                                         |
| `state`         | `present` (default) / `absent` (offboarding)         |
| `groups`        | secondary groups (e.g. `[greener, sudo]`)            |
| `sudo`          | `true` grants a validated sudoers drop-in            |
| `shell`         | login shell (`/usr/sbin/nologin` for machine users) |
| `authorized_keys` | list of **public** keys (never secrets)            |

The role iterates: ensures referenced groups, creates accounts, deploys public keys,
then manages sudo via `community.general.sudoers` (validated with `visudo`).

## Access matrix (GREENER)

- **Infra admins** (Lucas, Oriane, Houssem): `greener` + `sudo`.
- **Devs** (Joan, Etienne, Emi, Max): `greener`, no sudo, **no docker group in prod**.
- **`deploy`**: non-human CD account, `nologin` shell, scoped key.

## Offboarding

Set the user to `state: absent`, open a PR, replay `make deploy`. Membership is
declarative (`append: false`) and sudo drop-ins are removed automatically.
