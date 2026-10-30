# Design principles

- **Upstream first.** Use each app's own mechanisms and defaults. Keep custom code, boilerplate and patches to a minimum; if upstream can't do something, question the need before building it.
  Accepted exceptions: capi-argo-bridge; Argo Workflows + OpenTofu for the Keycloak realm; patches that only add resource requests/limits.
- **Comments are one line, for experts.** Say why, not what. Longer needs a reason.
