# Design principles

- **Upstream first.** Use each app's own mechanisms and defaults. Keep custom code, boilerplate and patches to a minimum; if upstream can't do something, question the need, and consider proposing an upstream issue or PR (suggest it; never file one automatically).
  Accepted exceptions: capi-argo-bridge; the tessdata image (Norwegian OCR for Paperless-ngx, whose image only adds languages as root); Argo Workflows + OpenTofu for the Keycloak realm; patches that only add resource requests/limits.
- **Declarative over imperative.** Desired state lives in git and is reconciled; nothing changes live state by hand or by script.
  Accepted exceptions: the 3-step bootstrap, break-glass, one-off cleanups.
- **No comment is the best comment.** If one is needed, it's one line for the operator: why it's done this way, never what the code does. Longer only for a hard reason.
- **Postgres for state.** An app that needs a database gets PostgreSQL from CloudNativePG, one cluster per app.
- **Zero trust, hardened by default.** Nothing is trusted for being in the cluster or on the network. Every app gets the hardening it takes without fighting upstream (non-root, read-only root, no capabilities, no service account token), not more.
- **Network policies everywhere.** Every pod is default-deny and opens only the flows it needs, on both ends.
- **Local accounts are break-glass.** People log in through Keycloak. Local accounts, admin included, are disabled, with a long random password in OpenBao readable only by what needs it, and their use alerts where the app makes it visible.
