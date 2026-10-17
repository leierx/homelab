# Docs

Longer-form explanations of how this homelab is put together. `AGENTS.md` is
the binding operational contract; these pages add the *why* and the procedures
that do not fit there.

- [access.md](access.md) — identity, the `homelab-*` groups, per-service roles
  and how to onboard or remove a person.
- [break-glass.md](break-glass.md) — how to get back in when SSO is broken.
- [openbao.md](openbao.md) — what OpenBao is, how a secret reaches a pod, and
  how to add or rotate one.
- [tech-choices.md](tech-choices.md) — the observability and secrets stack,
  what each piece is for, what was considered instead, and the storage budget.

## Host vs cluster

Two secret stores, on purpose:

- **sops** (`nixos/secrets.yaml`) holds only what the host needs before the
  cluster exists: WireGuard keys, the SSH host key and OpenBao's auto-unseal
  key.
- **OpenBao** (in the cluster) holds everything else, and pods read it through
  External Secrets. Nothing secret is committed under `gitops/`.
