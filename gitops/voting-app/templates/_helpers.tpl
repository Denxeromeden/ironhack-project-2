{{- define "voting-app.labels" -}}
app.kubernetes.io/managed-by: {{ .root.Release.Service | quote }}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
app.kubernetes.io/name: {{ .name | quote }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" | quote }}
{{- end }}

{{- define "voting-app.selectorLabels" -}}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
app.kubernetes.io/name: {{ .name | quote }}
{{- end }}

{{- define "voting-app.image" -}}
{{- $registry := required "global.imageRegistry must be injected by Argo CD" .root.Values.global.imageRegistry -}}
{{- $prefix := required "global.namePrefix must be injected by Argo CD" .root.Values.global.namePrefix -}}
{{- if not .tag -}}{{- fail (printf "image tag for %s must not be empty" .service) -}}{{- end -}}
{{- printf "%s/%s-%s:%s" (trimSuffix "/" $registry) $prefix .service .tag -}}
{{- end }}

{{- define "voting-app.topologySpread" -}}
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: DoNotSchedule
  labelSelector:
    matchLabels:
      app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
      app.kubernetes.io/name: {{ .name | quote }}
- maxSkew: 1
  topologyKey: kubernetes.io/hostname
  whenUnsatisfiable: ScheduleAnyway
  labelSelector:
    matchLabels:
      app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
      app.kubernetes.io/name: {{ .name | quote }}
{{- end }}
