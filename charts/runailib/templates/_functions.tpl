{{/*
Callers test the result with `if include "..."`: helpers that answer a yes/no question
print "true" or nothing.
*/}}

{{- define "runailib.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: runai
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/* lookup returns nothing under `helm template`, which is how ArgoCD renders. */}}
{{- define "runailib.canUseLookupFunc" -}}
{{- if eq (.Values.global._runai.mode | default "auto") "auto" -}}
true
{{- end -}}
{{- end -}}

{{/*
Fails the render when this release combines components that cannot share a release, or, when
"namespace" is given, is not installed into that namespace ("reason" says why).
Usage: include "runailib.validateRelease" (dict "context" . ["namespace" "runai" "reason" "..."])
*/}}
{{- define "runailib.validateRelease" -}}
{{- $ctx := .context -}}
{{- $r := $ctx.Values.global._runai -}}
{{- if and $r.controlPlane.enabled $r.cluster.enabled -}}
{{- fail "global._runai.controlPlane.enabled and global._runai.cluster.enabled cannot both be true: the cluster's pre-install hooks call the control plane, which must already be running. Install them as two releases (scripts/install.sh)." -}}
{{- end -}}
{{- if and $r.cluster.enabled $r.kaiScheduler.enabled -}}
{{- fail "global._runai.kaiScheduler.enabled must be false when global._runai.cluster.enabled is true: runai-cluster already installs KAI through kai-resource-management, and a second copy duplicates its CRDs and operator." -}}
{{- end -}}
{{- if and .namespace (ne $ctx.Release.Namespace .namespace) -}}
{{- fail (printf "%s must be installed into namespace %q (got %q): %s" $ctx.Chart.Name .namespace $ctx.Release.Namespace .reason) -}}
{{- end -}}
{{- end -}}

{{/*
docker-registry Secret for the image pull credentials in global._runai.registry.
Usage: include "runailib.registrySecret" (dict "context" . "name" "runai-reg-creds")
*/}}
{{- define "runailib.registrySecret" -}}
{{- $reg := .context.Values.global._runai.registry -}}
{{- if and $reg.server $reg.username $reg.password }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ .name }}
  namespace: {{ .context.Release.Namespace }}
  labels:
    {{- include "runailib.labels" .context | nindent 4 }}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: {{ dict "auths" (dict $reg.server (dict "username" $reg.username "password" $reg.password "auth" (printf "%s:%s" $reg.username $reg.password | b64enc))) | toJson | b64enc }}
{{- end }}
{{- end -}}

{{/*
runai-ca-cert, the Secret both upstream charts mount when global.customCA.enabled is true.
Rendered only when the CA is supplied inline; otherwise the operator creates the Secret.
It is a hook because the upstream pre-install hooks (control-plane secret-generator, cluster
pre-install) mount it: as a plain resource it would only be created after them, and they would
wait for it until the install timed out. Weight -20 runs it before upstream's lowest, -10.
*/}}
{{- define "runailib.customCASecret" -}}
{{- $ca := .Values.global._runai.customCA -}}
{{- if and .Values.global.customCA.enabled $ca.certificate }}
apiVersion: v1
kind: Secret
metadata:
  name: runai-ca-cert
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "runailib.labels" . | nindent 4 }}
  annotations:
    helm.sh/hook: pre-install,pre-upgrade
    helm.sh/hook-weight: "-20"
    helm.sh/hook-delete-policy: before-hook-creation
type: Opaque
data:
  runai-ca.pem: {{ $ca.certificate | b64enc }}
{{- end }}
{{- end -}}

{{/*
A Namespace the upstream chart writes into without creating it. Skipped when it already exists,
so an install never fails on a Namespace left by an earlier release; under `helm template` it is
always rendered, which ArgoCD applies idempotently.
Usage: include "runailib.namespace" (dict "context" . "name" "runai-reservation")
*/}}
{{- define "runailib.namespace" -}}
{{- $exists := false -}}
{{- if include "runailib.canUseLookupFunc" .context -}}
{{- $existing := lookup "v1" "Namespace" "" .name -}}
{{- $managed := and $existing (eq (dig "metadata" "annotations" "meta.helm.sh/release-name" "" $existing) .context.Release.Name) -}}
{{- $exists = and $existing (not $managed) -}}
{{- end -}}
{{- if not $exists }}
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .name }}
  labels:
    {{- include "runailib.labels" .context | nindent 4 }}
  annotations:
    helm.sh/resource-policy: keep
{{- end }}
{{- end -}}
