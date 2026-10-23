{{- /* Grafana alert provisioning file for rule group security; mounted by templates/alert-rules.yaml */ -}}
{{- define "homelab.alerts.security" -}}
apiVersion: 1
groups:
- orgId: 1
  name: security
  folder: homelab
  interval: 1m
  rules:
    - uid: admin-kubeconfig-used
      title: Admin kubeconfig used
      condition: C
      for: 0s
      noDataState: OK
      execErrState: Error
      labels:
        severity: warning
      annotations:
        summary: 'The host''s system:masters certificate was used: break-glass, or someone who shouldn''t have it.'
      data:
        - refId: A
          datasourceUid: loki
          relativeTimeRange:
            from: 300
            to: 0
          model:
            refId: A
            queryType: instant
            expr: sum(count_over_time({job="kube-audit"} | json | user_username="system:admin" [5m]))
        - refId: C
          datasourceUid: __expr__
          model:
            refId: C
            type: threshold
            expression: A
            conditions:
              - evaluator:
                  type: gt
                  params:
                    - 0
    - uid: rbac-changed-by-person
      title: RBAC changed outside Argo CD
      condition: C
      for: 0s
      noDataState: OK
      execErrState: Error
      labels:
        severity: warning
      annotations:
        summary: A role or binding was created, changed or deleted by something other than a ServiceAccount.
      data:
        - refId: A
          datasourceUid: loki
          relativeTimeRange:
            from: 300
            to: 0
          model:
            refId: A
            queryType: instant
            expr: sum by (user_username, objectRef_resource, objectRef_name) (count_over_time({job="kube-audit"} | json | objectRef_apiGroup="rbac.authorization.k8s.io" | verb=~"create|update|patch|delete" | user_username!~"system:serviceaccount:.*" | requestURI!~".*dryRun=All.*" [5m]))
        - refId: C
          datasourceUid: __expr__
          model:
            refId: C
            type: threshold
            expression: A
            conditions:
              - evaluator:
                  type: gt
                  params:
                    - 0
    - uid: secrets-or-exec-by-person
      title: Secrets read or pods entered by a person
      condition: C
      for: 0s
      noDataState: OK
      execErrState: Error
      labels:
        severity: info
      annotations:
        summary: Someone logged in through Keycloak read a Secret or used exec, attach or port-forward.
      data:
        - refId: A
          datasourceUid: loki
          relativeTimeRange:
            from: 300
            to: 0
          model:
            refId: A
            queryType: instant
            expr: sum by (user_username, objectRef_namespace, objectRef_resource, objectRef_subresource) (count_over_time({job="kube-audit"} | json | user_username=~"oidc:.*" | objectRef_resource="secrets" or objectRef_subresource=~"exec|attach|portforward" [5m]))
        - refId: C
          datasourceUid: __expr__
          model:
            refId: C
            type: threshold
            expression: A
            conditions:
              - evaluator:
                  type: gt
                  params:
                    - 0
    - uid: openbao-admin-login
      title: OpenBao admin login
      condition: C
      for: 0s
      noDataState: OK
      execErrState: Error
      labels:
        severity: info
      annotations:
        summary: Something logged in to OpenBao with the admin role (`just bao`, or a minted openbao-admin token).
      data:
        - refId: A
          datasourceUid: loki
          relativeTimeRange:
            from: 300
            to: 0
          model:
            refId: A
            queryType: instant
            expr: sum(count_over_time({namespace="openbao", container="openbao"} |= "\"type\":\"response\"" | json | auth_metadata_role="admin" [5m]))
        - refId: C
          datasourceUid: __expr__
          model:
            refId: C
            type: threshold
            expression: A
            conditions:
              - evaluator:
                  type: gt
                  params:
                    - 0
    - uid: admission-policy-warning
      title: Pod breaks an admission policy
      condition: C
      for: 0s
      noDataState: OK
      execErrState: Error
      labels:
        severity: info
      annotations:
        summary: A pod was admitted despite a Warn/Audit policy (gitops/charts/admission), e.g. a CPU limit or a missing memory limit.
      data:
        - refId: A
          datasourceUid: loki
          relativeTimeRange:
            from: 300
            to: 0
          model:
            refId: A
            queryType: instant
            expr: sum by (objectRef_namespace) (count_over_time({job="kube-audit"} |= "validation.policy.admission.k8s.io/validation_failure" | json [5m]))
        - refId: C
          datasourceUid: __expr__
          model:
            refId: C
            type: threshold
            expression: A
            conditions:
              - evaluator:
                  type: gt
                  params:
                    - 0
    - uid: network-policy-drops
      title: Traffic dropped by network policy
      condition: C
      for: 0s
      noDataState: OK
      execErrState: Error
      labels:
        severity: warning
      annotations:
        summary: 'Cilium denied traffic: a missing allow rule, or something probing where it shouldn''t.'
      data:
        - refId: A
          datasourceUid: mimir
          relativeTimeRange:
            from: 600
            to: 0
          model:
            refId: A
            instant: true
            expr: sum by (source, destination) (increase(hubble_drop_total{reason="POLICY_DENIED"}[5m])) > 0
        - refId: C
          datasourceUid: __expr__
          model:
            refId: C
            type: threshold
            expression: A
            conditions:
              - evaluator:
                  type: gt
                  params:
                    - 0
{{- end }}
