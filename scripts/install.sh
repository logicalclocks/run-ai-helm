#!/usr/bin/env bash
#
# Installs or upgrades Run:ai from this chart as three releases, in order:
#
#   1. runai-prerequisites  (namespace runai-prerequisites)  Prometheus Operator + GPU operator
#   2. runai-backend        (namespace runai-backend)        control plane
#   3. runai-cluster        (namespace runai)                cluster, with KAI Scheduler
#
# Between 2 and 3 it registers the cluster in the control plane (scripts/register_cluster.sh).
#
# Usage:
#   scripts/install.sh --domain runai.example.com [-f my-values.yaml ...]
#       [--skip-prerequisites] [--skip-control-plane] [--skip-cluster] [--dev]
#       [--cacert ca.pem | --insecure] [--cluster-name runai-cluster] [--admin-user test@run.ai]
#       [--timeout 20m]
#
# -f files are passed to every release, so one values file can carry the settings of all three
# (global.domain is set from --domain). --dev adds values.dev.yaml (fake GPUs).
# Run from a git checkout: it builds the chart's dependencies first.

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOMAIN=""
CLUSTER_NAME="runai-cluster"
TIMEOUT="20m"
VALUES=()
REGISTER_ARGS=()
SKIP_PREREQS=false
SKIP_CP=false
SKIP_CLUSTER=false

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log() { echo; echo "==> $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        -f|--values) VALUES+=(-f "$(realpath "$2")"); shift 2 ;;
        --dev) VALUES+=(-f "$CHART_DIR/values.dev.yaml"); shift ;;
        --skip-prerequisites) SKIP_PREREQS=true; shift ;;
        --skip-control-plane) SKIP_CP=true; shift ;;
        --skip-cluster) SKIP_CLUSTER=true; shift ;;
        --cacert) REGISTER_ARGS+=(--cacert "$2"); shift 2 ;;
        --insecure) REGISTER_ARGS+=(--insecure); shift ;;
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --admin-user) REGISTER_ARGS+=(--admin-user "$2"); shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done
[[ -n "$DOMAIN" ]] || { echo "ERROR: --domain is required" >&2; usage 1; }

"$CHART_DIR/helm_dependencies.sh"

release() {
    local name="$1" namespace="$2"; shift 2
    log "helm upgrade --install $name (namespace $namespace)"
    helm upgrade --install "$name" "$CHART_DIR" --namespace "$namespace" --create-namespace \
        --set global.domain="$DOMAIN" "$@" --wait --wait-for-jobs --timeout "$TIMEOUT"
}

if ! $SKIP_PREREQS; then
    release runai-prerequisites runai-prerequisites \
        -f "$CHART_DIR/values.prerequisites.yaml" ${VALUES[@]+"${VALUES[@]}"}
fi

if ! $SKIP_CP; then
    release runai-backend runai-backend \
        -f "$CHART_DIR/values.control-plane.yaml" ${VALUES[@]+"${VALUES[@]}"}
fi

if ! $SKIP_CLUSTER; then
    registration="$(mktemp --suffix=.yaml)"
    trap 'rm -f "$registration"' EXIT
    log "Registering cluster $CLUSTER_NAME in https://$DOMAIN"
    "$CHART_DIR/scripts/register_cluster.sh" --domain "$DOMAIN" --cluster-name "$CLUSTER_NAME" \
        --output "$registration" ${REGISTER_ARGS[@]+"${REGISTER_ARGS[@]}"}
    release runai-cluster runai \
        -f "$CHART_DIR/values.cluster.yaml" ${VALUES[@]+"${VALUES[@]}"} -f "$registration"
fi

log "Done. UI: https://$DOMAIN"
echo "Admin password: kubectl get secret runai-backend-gen-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d"
