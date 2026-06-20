{{- define "quote-api.name" -}}
{{- .Chart.Name }}
{{- end }}

{{- define "quote-api.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "quote-api.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{ include "quote-api.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "quote-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "quote-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
