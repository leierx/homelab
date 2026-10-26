{{/*
Build a merged map of all enabled addons and their combined metadata for this cluster.
*/}}
{{- define "fleet.mergedAddons" -}}
{{- $cluster := required "cluster.name is required" .Values.cluster.name -}}
{{- $files := .Files -}}
{{- $result := dict -}}

{{- range $addonName, $inlineCfg := .Values.addons -}}
  {{- $baseFile := printf "addons/%s/addon.yaml" $addonName -}}
  {{- $clusterFile := printf "clusters/%s/addons/%s/addon.yaml" $cluster $addonName -}}

  {{- $baseContent := $files.Get $baseFile -}}
  {{- $clusterContent := $files.Get $clusterFile -}}
  {{- $hasClusterChart := ne ($files.Get (printf "clusters/%s/addons/%s/Chart.yaml" $cluster $addonName)) "" -}}
  {{- $hasClusterManifests := not (empty ($files.Glob (printf "clusters/%s/addons/%s/manifests/**" $cluster $addonName))) -}}
  {{- if and (not $baseContent) (not $clusterContent) (not $hasClusterChart) (not $hasClusterManifests) -}}
    {{- fail (printf "Addon '%s' has neither %s nor %s" $addonName $baseFile $clusterFile) -}}
  {{- end -}}

  {{- $base := ternary (fromYaml $baseContent | default dict) (dict) (ne $baseContent "") -}}
  {{- $ovr := ternary (fromYaml $clusterContent | default dict) (dict) (ne $clusterContent "") -}}
  {{- $inline := ternary $inlineCfg (dict) (kindIs "map" $inlineCfg) -}}

  {{- $deps := uniq (concat (default list $base.dependencies) (default list $ovr.dependencies) (default list $inline.dependencies)) -}}
  {{- $extraSources := concat (default list $base.sources) (default list $ovr.sources) (default list $inline.sources) -}}
  {{- $ignoreDiffs := concat (default list $base.ignoreDifferences) (default list $ovr.ignoreDifferences) (default list $inline.ignoreDifferences) -}}

  {{- $merged := mergeOverwrite (deepCopy $base) (deepCopy $ovr) (deepCopy $inline) -}}
  {{- $_ := set $merged "dependencies" $deps -}}
  {{- $_ := set $merged "extraSources" $extraSources -}}
  {{- $_ := set $merged "ignoreDifferences" $ignoreDiffs -}}
  {{- $_ := set $result $addonName $merged -}}
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
  {{- fail (printf "Addon dependency '%s' is not enabled in clusters/%s/cluster.yaml" $addonName .cluster) -}}
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
