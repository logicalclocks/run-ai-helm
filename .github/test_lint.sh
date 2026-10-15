#!/usr/bin/env bash
# Render-time checks. Needs helm, the helm-schema plugin (dadav/helm-schema), helm-docs, and
# kubeconform on PATH (skipped with a warning when absent). Run ./helm_dependencies.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

echo ">> values.schema.json is generated from values.yaml"
for chart in . charts/*/; do
    chart="${chart%/}"
    cp -r "$chart" "$TMP/schema-check"
    (cd "$TMP/schema-check" && helm schema -r -p --no-dependencies -c . >/dev/null 2>&1)
    diff -q "$chart/values.schema.json" "$TMP/schema-check/values.schema.json" >/dev/null \
        || fail "$chart/values.schema.json is stale: run 'helm schema -r -p --no-dependencies'"
    rm -rf "$TMP/schema-check"
done

echo ">> README.md is generated from README.md.gotmpl"
helm-docs -g . -o temp-README.md >/dev/null 2>&1
diff -q README.md temp-README.md >/dev/null || { rm -f temp-README.md; fail "README.md is stale: run 'helm-docs -g .'"; }
rm -f temp-README.md

REGISTRATION="$TMP/registration.yaml"
cat > "$REGISTRATION" <<'EOF'
cluster:
  runai-cluster:
    controlPlane: {url: "https://runai.example.com", bootstrapToken: "test-token"}
    cluster: {uid: "00000000-0000-0000-0000-000000000000", url: "https://runai.example.com"}
EOF
CA_AND_TLS="--set global.customCA.enabled=true --set-string global._runai.customCA.certificate=PEM --set-string controlplane.tls.certificate=CRT --set-string controlplane.tls.key=KEY --set global._runai.registry.server=nvcr.io --set global._runai.registry.username=u --set global._runai.registry.password=p"

# release namespace values...
PASSING=(
    "runai-prerequisites runai-prerequisites -f values.prerequisites.yaml"
    "runai-prerequisites runai-prerequisites -f values.prerequisites.yaml -f values.dev.yaml"
    "runai-backend runai-backend -f values.control-plane.yaml --set global.domain=runai.example.com"
    "runai-backend runai-backend -f values.control-plane.yaml --set global.domain=runai.example.com $CA_AND_TLS"
    "runai-backend runai-backend -f values.control-plane.yaml -f values.openshift.yaml --set global.domain=runai.example.com"
    "runai-cluster runai -f values.cluster.yaml -f $REGISTRATION"
    "runai-cluster runai -f values.cluster.yaml -f $REGISTRATION $CA_AND_TLS"
    "runai-cluster runai -f values.cluster.yaml -f $REGISTRATION -f values.openshift.yaml"
    "kai-scheduler kai-scheduler -f values.kai-scheduler.yaml"
    "kai-scheduler kai-scheduler -f values.kai-scheduler.yaml -f values.openshift.yaml"
)
for case in "${PASSING[@]}"; do
    read -r release namespace args <<<"$case"
    echo ">> lint + template: $release ($namespace) $args"
    # shellcheck disable=SC2086
    helm lint --strict . --namespace "$namespace" $args >/dev/null || fail "helm lint: $case"
    # shellcheck disable=SC2086
    helm template "$release" . --namespace "$namespace" $args > "$TMP/out.yaml" || fail "helm template: $case"
    if command -v kubeconform >/dev/null; then
        kubeconform -kubernetes-version 1.34.0 -ignore-missing-schemas -summary "$TMP/out.yaml" >/dev/null \
            || fail "kubeconform: $case"
    fi
done
command -v kubeconform >/dev/null || echo "WARNING: kubeconform not found, manifests were not schema-checked"

# expected error substring | release namespace values...
FAILING=(
    "No component is enabled|r default"
    "global.domain must be set|runai-backend runai-backend -f values.control-plane.yaml"
    "must be installed into namespace \"runai-backend\"|r default -f values.control-plane.yaml --set global.domain=a.b"
    "must be installed into namespace \"runai\"|r default -f values.cluster.yaml -f $REGISTRATION"
    "runai-cluster.controlPlane.url, runai-cluster.cluster.uid|runai-cluster runai -f values.cluster.yaml"
    "cannot both be true|r runai -f values.cluster.yaml -f $REGISTRATION -f values.control-plane.yaml --set global.domain=a.b"
    "runai-cluster already installs KAI|r runai -f values.cluster.yaml -f $REGISTRATION -f values.kai-scheduler.yaml"
    "not both: both register|r p -f values.prerequisites.yaml --set gpu.fake-gpu-operator.enabled=true"
    "must be set together|runai-backend runai-backend -f values.control-plane.yaml --set global.domain=a.b --set controlplane.tls.certificate=x"
    "issuerRef.name is required|runai-backend runai-backend -f values.control-plane.yaml --set global.domain=a.b --set controlplane.tls.certManager.enabled=true"
    "value must be one of|r p -f values.prerequisites.yaml --set global._runai.mode=bogus"
)
for case in "${FAILING[@]}"; do
    expected="${case%%|*}"
    read -r release namespace args <<<"${case#*|}"
    echo ">> must fail with '$expected': $args"
    # shellcheck disable=SC2086
    if out="$(helm template "$release" . --namespace "$namespace" $args 2>&1)"; then
        fail "rendered, expected failure '$expected': ${case#*|}"
    fi
    grep -qF -- "$expected" <<<"$out" || fail "expected '$expected', got: $out"
done

echo "All checks passed"
