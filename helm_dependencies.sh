#!/usr/bin/env bash
# Subcharts first: each one packages runailib and its upstream chart into its own charts/,
# which the umbrella then packages.
set -euo pipefail
cd "$(dirname "$0")"

_helm_update() {
    for i in 1 2 3; do
        helm dependency update && return
        echo "helm dependency update failed in $(pwd) (attempt $i/3), retrying..."
        sleep 10
    done
    return 1
}

for d in charts/*/; do
    [[ "$d" == charts/runailib/ ]] && continue
    (cd "$d" && _helm_update)
done
_helm_update
