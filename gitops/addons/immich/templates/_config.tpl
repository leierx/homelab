{{/* Immich's config file. Locked: with a config file the admin UI can't change settings. */}}
{{- define "immich.config" -}}
# only SSO: Keycloak client immich, accounts created at first login, admin from the immich_role claim
oauth:
  enabled: true
  issuerUrl: https://auth.skinke.net/realms/homelab
  clientId: immich
  clientSecret: {{ `{{ .oidc_client_secret | quote }}` }}
  autoLaunch: true
passwordLogin:
  enabled: false
server:
  externalDomain: https://photos.skinke.net
machineLearning:
  urls: [http://immich-machine-learning:3003]
# Renovate brings new versions
newVersionCheck:
  enabled: false
# originals land under library/<user>/<year>/<date>/<file>, readable without Immich
storageTemplate:
  enabled: true
{{- end }}
{{/* named after the content: a change makes a new Secret, and the server waits for it and restarts */}}
{{- define "immich.configName" -}}
immich-config-{{ include "immich.config" . | sha256sum | trunc 8 }}
{{- end }}
