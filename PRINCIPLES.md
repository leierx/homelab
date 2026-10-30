# Design principles

- **Upstream first.** Use each app's own mechanisms and defaults. Keep custom code, boilerplate and patches to a minimum; if upstream can't do something, question the need, and consider proposing an upstream issue or PR (suggest it; never file one automatically).
  Accepted exceptions: capi-argo-bridge; Argo Workflows + OpenTofu for the Keycloak realm; patches that only add resource requests/limits.
- **Declarative over imperative.** Desired state lives in git and is reconciled; nothing changes live state by hand or by script.
  Accepted exceptions: the 3-step bootstrap, break-glass, one-off cleanups.
- **No comment is the best comment.** If one is needed, it's one line for the operator: why it's done this way, never what the code does. Longer only for a hard reason.
