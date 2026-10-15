# runai

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 3.0.20](https://img.shields.io/badge/AppVersion-3.0.20-informational?style=flat-square)

Installs NVIDIA Run:ai (control plane and cluster) and the KAI Scheduler it schedules with

The chart wraps the published upstream charts and adds the glue between them: release
profiles, validation, the Secrets the upstream charts expect to exist, and the cluster
registration step.

| Subchart | Upstream chart | Version | Repository |
| --- | --- | --- | --- |
| `controlplane` | `control-plane` | 3.0.20 | `https://helm.ngc.nvidia.com/nvidia/runai-oss` |
| `cluster` | `runai-cluster` (bundles `kai-resource-management` v0.18.3 and `kai-scheduler` v0.18.3) | 3.0.20 | `https://helm.ngc.nvidia.com/nvidia/runai-oss` |
| `kai` | `kai-scheduler` | v0.18.3 | `oci://ghcr.io/kai-scheduler/kai-scheduler` |
| `monitoring` | `kube-prometheus-stack` | 76.2.0 | `https://prometheus-community.github.io/helm-charts` |
| `gpu` | `gpu-operator`, `fake-gpu-operator` | v26.7.1, 0.0.62 | `https://helm.ngc.nvidia.com/nvidia`, `oci://ghcr.io/run-ai/fake-gpu-operator` |
| `runailib` | library chart with the shared helpers | | |

## Releases

The chart is installed once per namespace. Each release enables its components with a profile
file:

| Order | Release | Namespace | Profile | Installs |
| --- | --- | --- | --- | --- |
| 1 | `runai-prerequisites` | any (`runai-prerequisites`) | `values.prerequisites.yaml` | Prometheus Operator, NVIDIA GPU Operator (or the fake GPU operator with `values.dev.yaml`) |
| 2 | `runai-backend` | `runai-backend` | `values.control-plane.yaml` | Run:ai control plane: backend services, UI, Keycloak, PostgreSQL, Thanos, NATS |
| 3 | `runai-cluster` | `runai` | `values.cluster.yaml` | Run:ai cluster: operator, admission, agent, KAI Scheduler |
| | `kai-scheduler` | `kai-scheduler` | `values.kai-scheduler.yaml` | KAI Scheduler alone, for clusters without Run:ai |

The control plane and the cluster cannot share a release. The cluster's pre-install hooks call
the control-plane API with a cluster UUID and a bootstrap token, and the control plane issues
both only once it is running. `scripts/register_cluster.sh` registers the cluster and writes them
to a values file for release 3.

KAI Scheduler comes with release 3: `runai-cluster` depends on `kai-resource-management`, which
depends on `kai-scheduler`. The Run:ai operator writes KAI's `Config` and the
`kai-resource-management` node-pool controller writes one `SchedulingShard` per node pool. The
standalone `kai-scheduler` profile is for clusters that run KAI without Run:ai,
and the chart refuses to render it together with the cluster profile.

## Prerequisites

- Kubernetes >= 1.30, Helm 3.x or 4.x, `kubectl`, `curl`, `jq`.
- An ingress controller. The control plane creates an `Ingress` with class `nginx` by default
  (`global.ingress.ingressClass`, `nginx` or `haproxy`). OpenShift uses Routes.
- A DNS name for the control plane (`global.domain`) that resolves to the ingress controller, both
  from where `scripts/install.sh` runs and from inside the cluster.
- A TLS certificate for `global.domain`: PEM in `controlplane.tls`, a cert-manager issuer in
  `controlplane.tls.certManager`, or a `kubernetes.io/tls` Secret `runai-backend-tls` created in
  namespace `runai-backend` before the install.
- A default StorageClass for the PostgreSQL, Thanos (100Gi) and NATS volumes.
- A Prometheus Operator and an NVIDIA GPU stack (DCGM exporter). Release 1 installs both; skip it
  with `--skip-prerequisites` when the cluster already has them.

## Install

From a git checkout:

```sh
./helm_dependencies.sh
scripts/install.sh --domain runai.example.com -f my-values.yaml
```

`my-values.yaml` is passed to every release. A minimal one with a certificate for the domain:

```yaml
controlplane:
  tls:
    certificate: |
      -----BEGIN CERTIFICATE-----
      ...
    key: |
      -----BEGIN PRIVATE KEY-----
      ...
```

When the certificate is signed by a private CA, also set the CA so the cluster components trust
it:

```yaml
global:
  customCA:
    enabled: true
  _runai:
    customCA:
      certificate: |
        -----BEGIN CERTIFICATE-----
        ...
```

and pass `--cacert ca.pem` to `scripts/install.sh` for the registration calls.

`scripts/install.sh --help` lists the options: `--skip-prerequisites`, `--skip-control-plane`,
`--skip-cluster`, `--dev` (fake GPUs), `--cluster-name`, `--admin-user`, `--cacert`,
`--insecure`, `--timeout`.

The UI is at `https://<global.domain>`. The admin user is `test@run.ai`
(`controlplane.control-plane.tenantsManager.config.adminUsername`) and its password is generated:

```sh
kubectl get secret runai-backend-gen-tenants-manager -n runai-backend \
  -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d
```

### Step by step

```sh
helm upgrade --install runai-prerequisites . -n runai-prerequisites --create-namespace \
  -f values.prerequisites.yaml --wait

helm upgrade --install runai-backend . -n runai-backend --create-namespace \
  -f values.control-plane.yaml -f my-values.yaml --set global.domain=runai.example.com \
  --wait --wait-for-jobs --timeout 20m

scripts/register_cluster.sh --domain runai.example.com --output cluster-registration.yaml

helm upgrade --install runai-cluster . -n runai --create-namespace \
  -f values.cluster.yaml -f my-values.yaml -f cluster-registration.yaml \
  --wait --wait-for-jobs --timeout 20m
```

`cluster-registration.yaml` holds a bootstrap token. The control plane mints a new one on every
call, so regenerate the file before each install or upgrade of `runai-cluster`.

### Test clusters without GPUs

```sh
scripts/install.sh --domain runai.example.com --dev -f my-values.yaml
kubectl label node <node> run.ai/simulated-gpu-node-pool=default
```

`values.dev.yaml` replaces the NVIDIA GPU Operator with the fake GPU operator, which reports
8 Tesla-A10 GPUs on each labelled node.

### KAI Scheduler only

```sh
helm upgrade --install kai-scheduler . -n kai-scheduler --create-namespace \
  -f values.kai-scheduler.yaml --wait
```

KAI creates the queues `default-parent-queue` and `default-queue` on first install. Pods opt in
with `schedulerName: kai-scheduler` and the label `kai.scheduler/queue: default-queue`.

## OpenShift

Layer `values.openshift.yaml` on every release. Upstream detects OpenShift with `lookup`, which
returns nothing under `helm template`, so the file states it: it sets
`global.config.kubernetesDistribution: openshift` (Routes and SCCs in the control plane) and
forces OpenShift mode in `runai-cluster`, `kai-resource-management` and `kai-scheduler`. Leave
`global._runai.monitoring` off: the Run:ai operator uses `openshift-monitoring`.

## GitOps (ArgoCD)

ArgoCD renders with `helm template`, so:

- Set `global._runai.mode: install` (or `upgrade`): `lookup` returns nothing, and the chart then
  renders the `runai-reservation` Namespace unconditionally.
- Create one Application per release, synced in the order of the table above.
- The cluster Application needs the registration values. Run `scripts/register_cluster.sh` and
  store its output in a Secret-backed values source, since it holds a bootstrap token.

## Cluster ingress

The Run:ai cluster takes its routing settings through `clusterConfig`, a merge patch into its
`RunaiConfig`. To use HAProxy instead of nginx:

```yaml
cluster:
  runai-cluster:
    clusterConfig:
      global:
        ingress:
          ingressClass: haproxy
```

## Commercial charts

NVIDIA also publishes the commercial Run:ai line (2.x) as `control-plane` and `runai-cluster` in
`https://helm.ngc.nvidia.com/nvidia/runai`, which needs an NGC API key. Those charts take the
same install values (`controlPlane.url`, `controlPlane.clientSecret`, `cluster.uid`,
`cluster.url`, `clusterConfig`). Their `runai-cluster` 2.26.50 schedules with the proprietary
`runai-engine` (v3.41.19, from `nvcr.io/artifactory`) instead of KAI Scheduler. This chart wraps the
open-source 3.x line from `nvidia/runai-oss`.

## Upstream globals

Each subchart passes its upstream chart's values one level down, for example
`controlplane.control-plane.keycloakx`, `cluster.runai-cluster.kai-resource-management` or
`monitoring.kube-prometheus-stack.grafana`. The upstream charts also read these globals:

| Key | Read by | Purpose |
| --- | --- | --- |
| `global.domain` | control plane | FQDN of the control plane |
| `global.ingress.ingressClass` | control plane | `nginx` (default) or `haproxy` |
| `global.config.kubernetesDistribution` | control plane | `kubernetes` or `openshift` |
| `global.image.registry` | control plane, cluster | Registry for Run:ai images (default `nvcr.io/nvidia/runai-oss`) |
| `global.customCA.enabled` | control plane, cluster | Trust the CA in Secret `runai-ca-cert` |
| `global.imagePullSecrets` | control plane, KAI | Pull secrets as `[{name: ...}]` |
| `global.additionalImagePullSecrets` | cluster | Pull secrets as a list of names |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| cluster | object | `{}` | Cluster subchart: the upstream values under cluster.runai-cluster, including the registration values and KAI under cluster.runai-cluster.kai-resource-management.kai-scheduler. See charts/cluster/values.yaml. |
| controlplane | object | `{}` | Control-plane subchart: TLS for global.domain, and the upstream values under controlplane.control-plane. See charts/controlplane/values.yaml. |
| global._runai.cluster.enabled | bool | `false` | Run:ai cluster, including KAI Scheduler. Release namespace must be runai. Needs a running control plane and the values scripts/register_cluster.sh writes. |
| global._runai.controlPlane.enabled | bool | `false` | Run:ai control plane. Release namespace must be runai-backend. |
| global._runai.customCA.certificate | string | `""` | PEM CA bundle rendered into the runai-ca-cert Secret of the release namespace when global.customCA.enabled is true. Leave empty to create runai-ca-cert yourself. |
| global._runai.gpu.enabled | bool | `false` | NVIDIA GPU Operator, or the fake GPU operator (gpu.fake-gpu-operator.enabled). |
| global._runai.kaiScheduler.enabled | bool | `false` | Standalone KAI Scheduler, without Run:ai. Upstream documents namespace kai-scheduler. Never together with cluster, which bundles KAI. |
| global._runai.mode | string | `"auto"` | "auto" lets templates call lookup. Set "install" or "upgrade" when rendering with `helm template` (ArgoCD), where lookup returns nothing. |
| global._runai.monitoring.enabled | bool | `false` | kube-prometheus-stack. The Run:ai cluster requires a Prometheus Operator. |
| global._runai.registry.password | string | `""` | Registry password or token. |
| global._runai.registry.server | string | `""` | Registry host for the control-plane pull secret runai-reg-creds. Nothing is rendered unless server, username and password are all set. The images on nvcr.io/nvidia/runai-oss are public. |
| global._runai.registry.username | string | `""` | Registry user. |
| global.customCA.enabled | bool | `false` | Trust the CA in Secret runai-ca-cert (key runai-ca.pem). Needed when the control-plane certificate is not signed by a public CA. |
| global.domain | string | `""` | FQDN the control plane is served on. Required by the controlPlane component. |
| global.imagePullSecrets | list | `[]` | Pull secrets for control-plane and KAI pods, as [{name: <secret>}]. The Run:ai cluster reads global.additionalImagePullSecrets (a list of names) instead. |
| gpu | object | `{}` | GPU subchart: gpu.gpu-operator and gpu.fake-gpu-operator, each with an enabled switch. |
| kai | object | `{}` | Standalone KAI subchart: the upstream values under kai.kai-scheduler. |
| monitoring | object | `{}` | Monitoring subchart: the upstream values under monitoring.kube-prometheus-stack. |
