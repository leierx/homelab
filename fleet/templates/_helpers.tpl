{{/*
Resolve the cluster name from cluster.name or cluster-secret.yaml's metadata.name.
*/}}
{{- define "fleet.clusterName" -}}
{{- default .Values.metadata.name .Values.cluster.name | required "cluster.name or metadata.name is required" -}}
{{- end -}}

{{/*
Load clusters/<cluster>/cluster-secret.yaml from the chart if present.
*/}}
{{- define "fleet.gitClusterSecret" -}}
{{- $cluster := include "fleet.clusterName" . -}}
{{- $raw := .Files.Get (printf "clusters/%s/cluster-secret.yaml" $cluster) -}}
{{- if $raw -}}
{{- fromYaml $raw | toYaml -}}
{{- else -}}
{}
{{- end -}}
{{- end -}}

{{/*
Resolve the cluster labels: values metadata.labels, then cluster-secret.yaml in git, then the
live cluster Secret labels fleet-root passes as cluster.labels (CAPI clusters).
*/}}
{{- define "fleet.clusterLabels" -}}
{{- $gitSecret := fromYaml (include "fleet.gitClusterSecret" .) -}}
{{- $gitMeta := default dict $gitSecret.metadata -}}
{{- $labels := dict -}}
{{- if .Values.metadata.labels -}}
  {{- $labels = .Values.metadata.labels -}}
{{- else if $gitMeta.labels -}}
  {{- $labels = $gitMeta.labels -}}
{{- else if .Values.cluster.labels -}}
  {{- if kindIs "string" .Values.cluster.labels -}}
    {{- $labels = fromJson .Values.cluster.labels -}}
  {{- else if kindIs "map" .Values.cluster.labels -}}
    {{- $labels = .Values.cluster.labels -}}
  {{- end -}}
{{- end -}}
{{- $labels | toYaml -}}
{{- end -}}

{{/*
Build a merged map of all enabled addons and their combined metadata for this cluster.
Addons are enabled via labels on cluster-secret.yaml (or the live cluster Secret):
  fleet.io/<addon>.enable: "true"
  addons.homelab/<addon>: "true"
*/}}
{{- define "fleet.mergedAddons" -}}
{{- $cluster := include "fleet.clusterName" . -}}
{{- $files := .Files -}}
{{- $labels := fromYaml (include "fleet.clusterLabels" .) -}}

{{- $enabled := list -}}
{{- range $k, $v := $labels -}}
  {{- if eq (toString $v) "true" -}}
    {{- if and (hasPrefix "fleet.io/" $k) (hasSuffix ".enable" $k) -}}
      {{- $enabled = append $enabled (trimSuffix ".enable" (trimPrefix "fleet.io/" $k)) -}}
    {{- else if hasPrefix "addons.homelab/" $k -}}
      {{- $enabled = append $enabled (trimPrefix "addons.homelab/" $k) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- $result := dict -}}
{{- range $addonName := ($enabled | uniq | sortAlpha) -}}
  {{- $baseFile := printf "addons/%s/addon.yaml" $addonName -}}
  {{- $clusterFile := printf "clusters/%s/%s/addon.yaml" $cluster $addonName -}}

  {{- $baseContent := $files.Get $baseFile -}}
  {{- $clusterContent := $files.Get $clusterFile -}}
  {{- if and (not $baseContent) (not $clusterContent) -}}
    {{- fail (printf "Addon '%s' has neither %s nor %s" $addonName $baseFile $clusterFile) -}}
  {{- end -}}

  {{- $base := ternary (fromYaml $baseContent | default dict) (dict) (ne $baseContent "") -}}
  {{- $ovr := ternary (fromYaml $clusterContent | default dict) (dict) (ne $clusterContent "") -}}

  {{- $deps := uniq (concat (default list $base.dependencies) (default list $ovr.dependencies)) -}}
  {{- $extraSources := concat (default list $base.sources) (default list $ovr.sources) -}}
  {{- $ignoreDiffs := concat (default list $base.ignoreDifferences) (default list $ovr.ignoreDifferences) -}}

  {{- $merged := mergeOverwrite (deepCopy $base) (deepCopy $ovr) -}}
  {{- $_ := set $merged "dependencies" $deps -}}
  {{- $_ := set $merged "extraSources" $extraSources -}}
  {{- $_ := set $merged "ignoreDifferences" $ignoreDiffs -}}
  {{- $_ := set $result $addonName $merged -}}
{{- end -}}

{{- if empty $result -}}
  {{- fail (printf "No addons enabled for cluster '%s'; check fleet.io/<addon>.enable labels in clusters/%s/cluster-secret.yaml" $cluster $cluster) -}}
{{- end -}}

{{- $result | toYaml -}}
{{- end -}}

{{/*
Recursively calculate sync-wave depth from dependencies:
wave(addon) = 0 if no dependencies, else 1 + max(wave(dep))
*/}}
{{- define "fleet.calcWave" -}}
{{- $addonName := .addon -}}
{{- $all := .all -}}
{{- $depth := .depth -}}
{{- if gt $depth 20 -}}
  {{- fail (printf "Circular dependency detected involving addon '%s'" $addonName) -}}
{{- end -}}
{{- if not (hasKey $all $addonName) -}}
  {{- fail (printf "Addon dependency '%s' is not enabled in clusters/%s/cluster-secret.yaml" $addonName .cluster) -}}
{{- end -}}
{{- $cfg := index $all $addonName -}}
{{- $maxWave := 0 -}}
{{- range $dep := $cfg.dependencies -}}
  {{- $depWave := include "fleet.calcWave" (dict "addon" $dep "all" $all "depth" (add1 $depth) "cluster" $.cluster) | int -}}
  {{- $candidate := add1 $depWave -}}
  {{- if gt $candidate $maxWave -}}
    {{- $maxWave = $candidate -}}
  {{- end -}}
{{- end -}}
{{- printf "%d" $maxWave -}}
{{- end -}}

{{/*
Pull an OCI Helm chart through the registry mirror named by the cluster's fleet.io/oci-mirror label:
<mirror>/<upstream registry>/<path>. Repositories with a scheme (https:// chart repos, git) and
charts with mirror: false are left alone.
*/}}
{{- define "fleet.helmRepoURL" -}}
{{- $optOut := and (hasKey .helm "mirror") (not .helm.mirror) -}}
{{- if and .mirror (not (contains "://" .repoURL)) (not $optOut) -}}
{{- printf "%s/%s" .mirror .repoURL -}}
{{- else -}}
{{- .repoURL -}}
{{- end -}}
{{- end -}}
