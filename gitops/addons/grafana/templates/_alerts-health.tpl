{{- /* Grafana alert provisioning file for rule group health; mounted by templates/alert-rules.yaml */ -}}
{{- define "homelab.alerts.health" -}}
apiVersion: 1
groups:
- orgId: 1
  name: health
  folder: homelab
  interval: 1m
  rules:
    - uid: volume-filling-up
      title: Volume over 85% full
      condition: C
      for: 15m
      noDataState: OK
      execErrState: Error
      labels:
        severity: warning
      annotations:
        summary: A PVC is over 85% full.
      data:
        - refId: A
          datasourceUid: mimir
          relativeTimeRange:
            from: 600
            to: 0
          model:
            refId: A
            instant: true
            expr: max by (persistentvolumeclaim) (kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes) > 0.85
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
    - uid: pod-restarting
      title: Pod restarting
      condition: C
      for: 0s
      noDataState: OK
      execErrState: Error
      labels:
        severity: warning
      annotations:
        summary: A container restarted more than three times in 15 minutes.
      data:
        - refId: A
          datasourceUid: mimir
          relativeTimeRange:
            from: 600
            to: 0
          model:
            refId: A
            instant: true
            expr: sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[15m])) > 3
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
    - uid: node-not-ready
      title: Node not ready
      condition: C
      for: 5m
      noDataState: OK
      execErrState: Error
      labels:
        severity: critical
      annotations:
        summary: A node has been NotReady for 5 minutes.
      data:
        - refId: A
          datasourceUid: mimir
          relativeTimeRange:
            from: 600
            to: 0
          model:
            refId: A
            instant: true
            expr: max by (node) (kube_node_status_condition{condition="Ready", status="true"} == 0) + 1
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
    - uid: workflow-failed
      title: Workflow started by a CronWorkflow failed
      condition: C
      for: 0s
      noDataState: OK
      execErrState: Error
      labels:
        severity: warning
      annotations:
        summary: A workflow entered the Failed phase in the last 15 minutes. Every standing workflow here is started by a CronWorkflow (the controller's counter has no cron label).
      data:
        - refId: A
          datasourceUid: mimir
          relativeTimeRange:
            from: 900
            to: 0
          model:
            refId: A
            instant: true
            expr: sum by (namespace) (increase(argo_workflows_total_count{phase="Failed"}[15m])) > 0
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
    - uid: argocd-app-unhealthy
      title: Argo CD application unhealthy
      condition: C
      for: 15m
      noDataState: OK
      execErrState: Error
      labels:
        severity: warning
      annotations:
        summary: An Argo CD application has been Degraded, Missing or Unknown for 15 minutes.
      data:
        - refId: A
          datasourceUid: mimir
          relativeTimeRange:
            from: 600
            to: 0
          model:
            refId: A
            instant: true
            expr: max by (name, health_status) (argocd_app_info{health_status!~"Healthy|Progressing|Suspended"})
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
    - uid: secret-sync-failing
      title: Secret sync failing
      condition: C
      for: 15m
      noDataState: OK
      execErrState: Error
      labels:
        severity: warning
      annotations:
        summary: An ExternalSecret or PushSecret has not been Ready for 15 minutes.
      data:
        - refId: A
          datasourceUid: mimir
          relativeTimeRange:
            from: 600
            to: 0
          model:
            refId: A
            instant: true
            expr: max by (exported_namespace, name) ({__name__=~"externalsecret_status_condition|pushsecret_status_condition", condition="Ready", status="False"}) > 0
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
    - uid: openbao-sealed
      title: OpenBao sealed
      condition: C
      for: 5m
      noDataState: Alerting
      execErrState: Error
      labels:
        severity: critical
      annotations:
        summary: 'OpenBao is sealed or not reporting: no secret can be read or generated.'
      data:
        - refId: A
          datasourceUid: mimir
          relativeTimeRange:
            from: 600
            to: 0
          model:
            refId: A
            instant: true
            expr: max(vault_core_unsealed)
        - refId: C
          datasourceUid: __expr__
          model:
            refId: C
            type: threshold
            expression: A
            conditions:
              - evaluator:
                  type: lt
                  params:
                    - 1
    - uid: certificate-expiring
      title: Certificate expiring
      condition: C
      for: 1h
      noDataState: OK
      execErrState: Error
      labels:
        severity: warning
      annotations:
        summary: A cert-manager certificate expires within 14 days; renewal is failing.
      data:
        - refId: A
          datasourceUid: mimir
          relativeTimeRange:
            from: 600
            to: 0
          model:
            refId: A
            instant: true
            expr: min by (namespace, name) (certmanager_certificate_expiration_timestamp_seconds - time()) < 14 * 86400
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
