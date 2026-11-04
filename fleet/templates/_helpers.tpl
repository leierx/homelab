{{/* A YAML file from the chart as a map, or an empty map if it doesn't exist. */}}
{{- define "fleet.readYaml" -}}
{{- $raw := .files.Get .path -}}
{{- $out := dict -}}
{{- if $raw -}}
  {{- $out = fromYaml $raw | default dict -}}
  {{- if hasKey $out "Error" -}}
    {{- fail (printf "%s: %s" .path $out.Error) -}}
  {{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/* Deep-merges .src into .dst in place: maps recurse, everything else (lists too) is replaced. */}}
{{- define "fleet.deepMerge" -}}
{{- $dst := .dst -}}
{{- range $k, $v := .src -}}
  {{- if and (kindIs "map" $v) (kindIs "map" (index $dst $k)) -}}
    {{- include "fleet.deepMerge" (dict "dst" (index $dst $k) "src" $v) -}}
  {{- else -}}
    {{- $_ := set $dst $k (deepCopy $v) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/* Layer directories in merge order: addons/<n> < envs/<e>/<n> < clusters/<c>/<n>. */}}
{{- define "fleet.layers" -}}
{{- $layers := list (printf "addons/%s" .name) -}}
{{- if .env -}}
  {{- $layers = append $layers (printf "envs/%s/%s" .env .name) -}}
{{- end -}}
{{- $layers = append $layers (printf "clusters/%s/%s" .cluster .name) -}}
{{- toYaml $layers -}}
{{- end -}}

{{/*
Every addon enabled on .Values.cluster, merged across its layers, with its
resolved manager, layer dirs and sync wave. Fails on an invalid graph.
*/}}
{{- define "fleet.addons" -}}
{{- $files := .Files -}}
{{- $cluster := required "cluster is required" .Values.cluster -}}
{{- $clusterPath := printf "clusters/%s/cluster.yaml" $cluster -}}
{{- if not ($files.Get $clusterPath) -}}
  {{- fail (printf "%s does not exist" $clusterPath) -}}
{{- end -}}
{{- $clusterCfg := fromYaml (include "fleet.readYaml" (dict "files" $files "path" $clusterPath)) -}}
{{- $env := default "" $clusterCfg.env -}}
{{- $enabled := dict -}}
{{- if $env -}}
  {{- $envPath := printf "envs/%s/env.yaml" $env -}}
  {{- if not ($files.Get $envPath) -}}
    {{- fail (printf "%s sets env %q, but %s does not exist" $clusterPath $env $envPath) -}}
  {{- end -}}
  {{- $envCfg := fromYaml (include "fleet.readYaml" (dict "files" $files "path" $envPath)) -}}
  {{- $enabled = deepCopy (default dict $envCfg.addons) -}}
{{- end -}}
{{- include "fleet.deepMerge" (dict "dst" $enabled "src" (default dict $clusterCfg.addons)) -}}
{{- $defaultManager := default "self" $clusterCfg.managedBy -}}

{{- $addons := dict -}}
{{- range $name, $on := $enabled -}}
  {{- if eq (toString $on) "true" -}}
    {{- $layers := fromYamlArray (include "fleet.layers" (dict "name" $name "env" $env "cluster" $cluster)) -}}
    {{- $merged := dict -}}
    {{- $deps := list -}}
    {{- $sources := list -}}
    {{- $defined := false -}}
    {{- range $layer := $layers -}}
      {{- $path := printf "%s/addon.yaml" $layer -}}
      {{- if $files.Get $path -}}
        {{- $defined = true -}}
        {{- $cfg := fromYaml (include "fleet.readYaml" (dict "files" $files "path" $path)) -}}
        {{- $deps = concat $deps (default list $cfg.dependencies) -}}
        {{- $sources = concat $sources (default list $cfg.sources) -}}
        {{- include "fleet.deepMerge" (dict "dst" $merged "src" $cfg) -}}
      {{- end -}}
    {{- end -}}
    {{- if not $defined -}}
      {{- fail (printf "addon %q is enabled on cluster %q but has no addon.yaml in %s" $name $cluster (join ", " $layers)) -}}
    {{- end -}}
    {{- $manager := default $defaultManager $merged.managedBy -}}
    {{- $_ := set $merged "manager" (ternary $cluster $manager (eq $manager "self")) -}}
    {{- $_ := set $merged "dependencies" (uniq $deps) -}}
    {{- $_ := set $merged "sources" $sources -}}
    {{- $_ := set $merged "nonBlocking" (eq (toString $merged.nonBlocking) "true") -}}
    {{- $_ := set $merged "layers" $layers -}}
    {{- $_ := set $addons $name $merged -}}
  {{- end -}}
{{- end -}}

{{- range $name, $a := $addons -}}
  {{- range $dep := $a.dependencies -}}
    {{- $d := index $addons $dep -}}
    {{- if not $d -}}
      {{- fail (printf "addon %q depends on %q, which is not enabled on cluster %q" $name $dep $cluster) -}}
    {{- end -}}
    {{- if ne $a.manager $d.manager -}}
      {{- fail (printf "addon %q (managed by %q) depends on %q (managed by %q): dependencies must stay within one manager" $name $a.manager $dep $d.manager) -}}
    {{- end -}}
    {{- if and (not $a.nonBlocking) $d.nonBlocking -}}
      {{- fail (printf "blocking addon %q depends on non-blocking addon %q" $name $dep) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- $n := len $addons -}}
{{- $waves := dict -}}
{{- range $name, $_ := $addons -}}
  {{- $_ := set $waves $name 0 -}}
{{- end -}}
{{- range $pass := until $n -}}
  {{- range $name, $a := $addons -}}
    {{- $w := 0 -}}
    {{- range $dep := $a.dependencies -}}
      {{- $w = max $w (add1 (index $waves $dep)) -}}
    {{- end -}}
    {{- $_ := set $waves $name $w -}}
  {{- end -}}
{{- end -}}
{{- range $name, $a := $addons -}}
  {{- $w := index $waves $name -}}
  {{- if ge (int $w) $n -}}
    {{- fail (printf "dependency cycle involving addon %q" $name) -}}
  {{- end -}}
  {{- $_ := set $a "wave" $w -}}
{{- end -}}

{{- toYaml $addons -}}
{{- end -}}
