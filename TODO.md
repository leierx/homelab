- [ ] Rotate Secrets.
- [ ] Database passwords: replace the ESO/Reloader rotation with CNPG `DatabaseRole.password` once 1.31 ships; use dedicated roles, not the bootstrap owner.
- [ ] Tetragon: once a tripwire policy has stayed quiet for a couple of weeks, set its `policy-mode` to `enforce` (fleet/addons/tetragon/manifests/tracing-policies.yaml).
- [ ] Alerting: verify skinke.net in Resend (its DKIM, MX and SPF records at 1984 Hosting) so critical alerts actually mail; until then Alerta is the only channel.
- [ ] k3s 1.37: upgrade once NixOS 26.11 is adopted (it ships `k3s_1_37`) and Cilium (1.21), cert-manager (1.22) and CloudNativePG (1.31) releases supporting Kubernetes 1.37 are deployed; add `gateway-api-crd` to `--disable` in `nixos/k3s.nix` in the same change, or k3s takes the Gateway API CRDs from Envoy Gateway. Snapshot `state.db` first.
- [ ] Images: get images onto the node without a registry at boot (e.g. k3s airgap images after a k3s bump), and decide which to keep and which to prune.
- [ ] Backups: manual restore drill of one volume plus a short runbook in docs/.
- [ ] Paperless-ngx AI: try its optional AI features (suggestions, document chat) with a small local model; slow is fine, heavy is not.
- [ ] OpenBao: switch to the distroless image once the chart can run it without a shell (openbao/openbao-helm#205, #248). `just bao` and the break-glass steps in docs/README.md run `sh` in the pod; move them to a port-forward and a local `bao`.
- [ ] OpenCloud: delete the groups it synced from the old Keycloak groups claim (Admin settings → Groups); tokens no longer recreate them.

## Upstream

Suggest these upstream; file nothing automatically.

- [ ] Tetragon: `matchWorkloads` can't load in the `imaHash` variant of the `bprm_check_security` program (`populating map failed as map 'workloads_map' was not found`, `bpf_generic_lsm_ima_bprm_v61.o`, 1.8.0), so `tripwire-exec-paperless` is a whole copy of `tripwire-exec` instead of one scoped selector.
- [ ] Grafana chart: `templates/clusterrole.yaml` grants `configmaps` and `secrets` whenever any sidecar is enabled, regardless of `sidecar.*.resource`; we ship our own `grafana-dashboards` ClusterRole through `rbac.useExistingClusterRole` instead.
- [ ] nixpkgs `system.autoUpgrade`: `allowReboot` only compares the booted kernel, initrd and modules, not `kernel-params`, so a parameter-only change (e.g. `ima_hash=sha256`) waits for the next kernel bump or a manual reboot.
