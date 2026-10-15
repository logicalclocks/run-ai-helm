# run-ai-helm: development rules

Umbrella chart `runai` that installs NVIDIA Run:ai and KAI Scheduler from their published charts.
Its layout follows `hopsworks-helm`: the root `templates/` only validates, every component is a
local wrapper subchart under `charts/`, and shared helpers live in the `runailib` library chart.

## Layout

| Path | Purpose |
| --- | --- |
| `Chart.yaml` | Subcharts, each behind a `global._runai.<component>.enabled` condition |
| `values.yaml` | `global._runai` (this chart) plus the upstream globals it documents |
| `values.<profile>.yaml` | One file per release: `prerequisites`, `control-plane`, `cluster`, `kai-scheduler` |
| `values.dev.yaml`, `values.openshift.yaml` | Overlays layered on a profile |
| `charts/runailib` | Library: labels, release validation, registry/CA Secrets, lookup-gated Namespace |
| `charts/<wrapper>` | Depends on `runailib` and one upstream chart; upstream values sit under `<wrapper>.<upstream>` |
| `scripts/register_cluster.sh` | Registers the cluster in the control plane, writes the cluster release's values |
| `scripts/install.sh` | Runs the three releases in order |
| `.github/test_lint.sh` | Schema/docs freshness, lint + template over the profile matrix, expected failures |

## Rules

- **One release per namespace.** The control plane and the cluster never share a release: the
  cluster's pre-install hooks call the control-plane API with a UUID and bootstrap token that
  only a running control plane issues. `runailib.validateRelease` enforces this.
- **No second KAI.** `runai-cluster` already installs KAI (`kai-resource-management` ->
  `kai-scheduler`). The `kai` subchart is for KAI without Run:ai and must not render with `cluster`.
- **Secrets that upstream pre-install hooks mount are hooks themselves.** `runai-ca-cert` is mounted by
  the control plane's `secret-generator` and the cluster's `pre-install` Job, so it is a
  `pre-install,pre-upgrade` hook at weight -20 (upstream's lowest is -10). A plain resource would
  only be created after those hooks and the install would time out.
- **Do not render `runai-reg-creds` in namespace `runai`.** The `runai-cluster` hooks write it there from
  the control plane's install config.
- **Gate `lookup`** with `runailib.canUseLookupFunc`; ArgoCD renders with `helm template`.
- **Pin upstream versions** to a published release, and keep the KAI version equal to the one
  `runai-cluster` bundles. Bump `appVersion` in `Chart.yaml`, `charts/controlplane` and
  `charts/cluster` with the Run:ai version: `scripts/register_cluster.sh` sends the cluster
  chart's `appVersion` to `cluster-install-info`.

## After changing values or templates

```sh
./helm_dependencies.sh                       # also after any change to charts/runailib
helm schema -r -p --no-dependencies          # regenerates every values.schema.json
helm-docs -g .                               # regenerates README.md from README.md.gotmpl
.github/test_lint.sh
```

Do not edit `values.schema.json` or `README.md` by hand.

## Upstream facts this chart relies on

| Fact | Source |
| --- | --- |
| `runai-cluster` hard-codes `namespace: runai` in its templates | packaged chart `templates/` |
| Cluster hooks take `cluster.uid` and `controlPlane.bootstrapToken` as literal args | `templates/hooks/pre-install-job.yaml` |
| The post-install RBAC hook writes into `runai-reservation`, which no template creates | `run-ai/local-dev.sh` `deploy_runai_cluster` |
| Registration API: `POST /api/v1/token` (password grant), `GET`/`POST /api/v1/clusters`, `GET /api/v1/clusters/{uuid}/cluster-install-info` | `runai-installer/installer/internal/orchestrator2/actions/` |
| Keycloak's main container needs `keycloakx.database.*` set explicitly | `run-ai/.local-dev/values-cp.yaml` |
| The operator finds the Prometheus Operator in any namespace, by Deployment name matching `(prometheus\|rancher-monitoring).*operator`, so `charts/monitoring` sets `fullnameOverride` | `go-operator/pkg/controller-utils/dependency_checkers.go` |
| KAI gpu-fractioning (bundled by `runai-cluster`) needs an r615+ driver; the GPU Operator default is older, so `charts/gpu` pins `driver.version` | `KAI-Scheduler/docs/operator/README.md` |
