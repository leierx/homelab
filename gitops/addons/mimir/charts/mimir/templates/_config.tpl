{{- define "mimir.config" -}}
multitenancy_enabled: false
usage_stats:
  enabled: false
server:
  http_listen_port: 8080
  grpc_listen_port: 9095
  grpc_server_max_recv_msg_size: 104857600
  grpc_server_max_send_msg_size: 104857600
activity_tracker:
  filepath: /data/activity.log
common:
  storage:
    backend: filesystem
blocks_storage:
  filesystem:
    dir: /data/blocks
  tsdb:
    dir: /data/tsdb
  bucket_store:
    sync_dir: /data/tsdb-sync
ruler_storage:
  filesystem:
    dir: /data/rules
ruler:
  rule_path: /data/ruler
compactor:
  data_dir: /data/compactor
  sharding_ring:
    kvstore:
      store: memberlist
distributor:
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: memberlist
ingester:
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: memberlist
    replication_factor: 1
store_gateway:
  sharding_ring:
    replication_factor: 1
limits:
  compactor_blocks_retention_period: {{ .Values.retention }}
  {{- toYaml .Values.limits | nindent 2 }}
{{- end }}
