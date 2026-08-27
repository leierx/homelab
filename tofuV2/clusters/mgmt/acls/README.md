# acls/

Empty on purpose (v1 = structure only). Drop `<name>.yaml` here and re-plan; the network picks it up as `mgmt-<name>`.

Schema:

```yaml
description: "Allow ArgoCD agent from prod/test to reach mgmt"
egress: []
ingress:
  - action: allow          # allow | allow-stateless | drop | reject
    source: "@external"    # CIDR, IP list, or @internal/@external
    destination_port: "6443"
    protocol: tcp          # tcp | udp | icmp4 | icmp6
    state: enabled         # enabled | disabled | logged
```

v2 goal: allow prod and test to reach argocd-agent in mgmt.
