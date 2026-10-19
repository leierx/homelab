# Docs

Longer-form explanations of how this homelab is put together. `AGENTS.md` is
the binding operational contract; these pages add the *why* and the procedures
that do not fit there. `README.md` at the repo root is the overview.

- [bootstrap.md](bootstrap.md) — bare metal to a synced cluster.
- [dodde.md](dodde.md) — dodde's Fedora VM: what runs, how to get in, the
  handover, its isolation, and how to restore it.
- [immich.md](immich.md) — photos: what runs where, logins and the phone
  app, what is public, bulk upload, restore, upgrades.
- [operations.md](operations.md) — updates, backups and restore, certificates,
  observability and alerting.
- [access.md](access.md) — identity, the `homelab-*` groups, per-service roles
  and how to onboard or remove a person.
- [break-glass.md](break-glass.md) — how to get back in when SSO is broken.
- [openbao.md](openbao.md) — what OpenBao is, how a secret reaches a pod, how
  to add or rotate one, and the sops/OpenBao split.
- [tech-choices.md](tech-choices.md) — what each piece is for, what was
  considered instead, the storage budget, and the free-software audit.
