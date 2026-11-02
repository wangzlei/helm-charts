# AWS
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

## Introduction
The Amazon CloudWatch Observability Helm Chart provides easy mechanisms to setup the [Amazon CloudWatch Agent Operator](https://github.com/aws/amazon-cloudwatch-agent-operator) to manage the [CloudWatch Agent](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Install-CloudWatch-Agent.html) on Kubernetes clusters.

## Getting Started
Full instructions can be found in the [AWS documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Observability-EKS-addon.html)

### Installation
1. You must have Helm installed to use this chart. For more information about installing Helm, see the [Helm documentation](https://helm.sh/docs/).
2. After you have installed Helm, enter the following commands. Replace my-cluster-name with the name of your cluster, and replace my-cluster-region with the Region that the cluster runs in.

```bash
helm repo add aws-observability https://aws-observability.github.io/helm-charts
helm repo update aws-observability
helm install --wait --create-namespace --namespace amazon-cloudwatch amazon-cloudwatch aws-observability/amazon-cloudwatch-observability --set clusterName=my-cluster-name --set region=my-cluster-region
```

By default, the helm chart will enable [Container Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html) enhanced observability with container logging, and [CloudWatch Application Signals](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-Application-Monitoring-Sections.html). This helps you to collect infrastructure metrics, application performance telemetry, and container logs from the Amazon EKS cluster.

## vLLM model-server metrics

Set under `otelContainerInsights.solutions.vllm`, on by default. The agent on each node
scrapes the vLLM servers on that node; the cluster-scraper is not involved.

### Which vLLM servers are scraped

Two receivers find them, with nothing to configure:

- **KServe:** the `kserve-container` of an InferenceService's predictor pods (labels
  `serving.kserve.io/inferenceservice` and `component: predictor`), whatever its image.
  Transformer and explainer pods are not scraped. KServe does not label which engine a
  predictor runs, so one shared receiver scrapes each predictor once and feeds every
  model-server pipeline; this one keeps the vLLM series (`vllm:*`, `http_*`) and the
  [SGLang pipeline](#sglang-model-server-metrics) keeps `sglang:*`.
- **Anything else:** any container whose image name contains `vllm`
  (`vllm/vllm-openai`, or a mirror of it), outside KServe predictors and KubeRay pods.

The chart reads no scrape labels or annotations of its own from customer pods. A vLLM server
outside KServe built from an image without `vllm` in its name is not found automatically;
scrape it with a PodMonitor or a custom agent configuration.

The port is resolved in this order, highest precedence first:

1. on KServe pods, the serving runtime's `prometheus.kserve.io/port` (and `prometheus.kserve.io/path`)
2. the port the container declares
3. the server's default: 8080 for KServe, 8000 for `vllm serve`

On KServe pods only the `kserve-container` is scraped, never the queue-proxy, which serves the
model server's metrics a second time. vLLM's `http_*` series have no engine prefix, so a
predictor running another engine that also exports unprefixed `http_*` series has those in
this pipeline too.

Every target carries the resource attribute `aws.service.type = ai_inference`, so a consumer
can find model-serving telemetry without knowing which metric names belong to it. vLLM only
serves inference, so the value is fixed.

### The vLLM metric service name

`service.name` on the engine's metrics is resolved in this order, highest precedence first. The
SGLang solution uses the same order.

1. the pod annotation `resource.opentelemetry.io/service.name`
2. the InferenceService name
3. the workload name — Deployment, else StatefulSet, DaemonSet, Job or ReplicaSet
4. the pod name

The InferenceService outranks the Deployment because in KServe Serverless mode the
Deployment name embeds the Knative revision generation
(`<isvc>-predictor-00004-deployment`) and so changes on every redeploy. The
`app.kubernetes.io/instance` and `app.kubernetes.io/name` labels are not used.

The pipeline also promotes the scraped `pod`/`namespace` labels to resource attributes and
runs `k8sattributes` pod association, so `k8s.workload.name` resolves to the owning
Deployment rather than to the ReplicaSet — whose pod-template hash likewise changes on
every redeploy.

### Not found automatically

- Pods that KubeRay labels `ray.io/is-ray-node=yes`, whatever their image: Ray serves an
  engine's metrics through its own metrics port.
- A KServe LLMInferenceService running vLLM from the llm-d image (`ghcr.io/llm-d/llm-d-cuda`):
  its pods carry neither the InferenceService labels nor a `vllm` image name, and serve
  HTTPS when KServe's TLS is on.

## SGLang model-server metrics

Set under `otelContainerInsights.solutions.sglang`, on by default. The agent on each node
scrapes the SGLang servers on that node; the cluster-scraper is not involved.

SGLang serves metrics only when started with `--enable-metrics`; add `--enable-mfu-metrics`
for the `sglang:estimated_*` counters. Without the flag the server is still found, and its
scrape fails.

### Which SGLang servers are scraped

- **KServe:** the model container of an InferenceService's predictor pods, whatever its
  image, through the receiver shared with [vLLM](#which-vllm-servers-are-scraped); this
  pipeline keeps its `sglang:*` series.
- **Anything else:** any container whose image name contains `sglang` (`lmsysorg/sglang`, or
  a mirror of it), outside KServe predictors and KubeRay pods, including the model container
  of a KServe LLMInferenceService.

The chart reads no scrape labels or annotations of its own from customer pods.

The port is resolved in this order, highest precedence first:

1. on KServe pods, the serving runtime's `prometheus.kserve.io/port` (and `prometheus.kserve.io/path`)
2. the port the container declares
3. the server's default: 8080 for KServe, 30000 for `sglang.launch_server`

Only `sglang:*` series are kept. Every target carries `aws.service.type = ai_inference`, as
for vLLM.

### The SGLang metric service name

`service.name` is resolved as for [vLLM](#the-vllm-metric-service-name): the pod annotation
`resource.opentelemetry.io/service.name`, then the InferenceService name, then the workload,
then the pod.

## KServe control-plane metrics

Set under `otelContainerInsights.solutions.kserve.controlPlane`, on by default. The
cluster-scraper finds the `kserve-controller-manager` pod by its
`control-plane: kserve-controller-manager` label in `namespace` (default `kserve`), so a
cluster without KServe has no target. The controller binds its plain metrics to
`127.0.0.1:8080`, so they are scraped through its kube-rbac-proxy on `:8443`, with the agent's
service-account token.

Only the operator's own `controller_runtime_*` and `leader_election_*` families are kept.
client-go's `workqueue_*` and `rest_client_*` are dropped: the apiserver pipeline already
publishes those names under its own scope. The series are attributed to the controller pod
and its Deployment.

KServe is a control plane only and is never in the request path: request-level metrics for
an InferenceService come from the model server (`solutions.vllm`) and, in Serverless mode,
from the Knative queue-proxy (`solutions.knative.dataPlane`).

## Knative Serving metrics

Set under `otelContainerInsights.solutions.knative`, both on by default:

- `dataPlane`: request metrics from the queue-proxy sidecar of every revision pod, scraped by
  the agent on the pod's node. Predictor revisions of a KServe InferenceService carry
  `aws.service.type = ai_inference`.
- `controlPlane`: autoscaler, activator, controller and webhook metrics, scraped by the
  cluster-scraper and attributed to the component's pod and Deployment.

Which sources exist depends on the KServe deployment mode. In **Serverless** mode (KServe's
default) an InferenceService becomes a Knative Service, so all of them are present. In
**RawDeployment** mode there is no queue-proxy and no `knative-serving` namespace, so only
`vllm` and `kserve.controlPlane` find targets; use the HPA metrics from kube-state-metrics
for the autoscaling view. Note that the request-level metrics are emitted by the Knative
queue-proxy rather than by KServe, which is a control plane only and is never in the request
path — hence `knative.dataPlane`, not `kserve`.

### Knative Serving 1.19 renamed every metric

`solutions.knative.*` handles both name sets. Serving ≤ 1.18 emits OpenCensus names
(`revision_*`, `autoscaler_*`); ≥ 1.19 moved to the OpenTelemetry SDK and renamed them with
a `kn` prefix (`autoscaler_desired_pods` → `kn_revision_pods_desired`).

On ≥ 1.19 Knative exports no metrics by default: the components' port 9090 and the
queue-proxy's port 9091 refuse connections until Knative is told to serve Prometheus.
`metrics-protocol` covers the control plane (`solutions.knative.controlPlane`) and
`request-metrics-protocol` the queue-proxy (`solutions.knative.dataPlane`):

```bash
kubectl -n knative-serving patch cm config-observability --type merge \
  -p '{"data":{"metrics-protocol":"prometheus","request-metrics-protocol":"prometheus"}}'
kubectl -n knative-serving rollout restart deployment
```

The components read `metrics-protocol` only at startup, hence the restart. The queue-proxy
setting applies to revision pods started after the change.

### Istio sidecars with STRICT mTLS

KServe and Knative do not inject Istio sidecars into revision pods by default. If a namespace
turns sidecar injection on and enforces `STRICT` mTLS, the sidecar rejects the agent's
plain-HTTP scrape, because the agent is not part of the mesh. Allow plain text on the metrics
port of those pods, for example for KServe predictors:

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: allow-metrics-scrape
  namespace: <model-namespace>
spec:
  selector:
    matchLabels:
      component: predictor
  mtls:
    mode: STRICT
  portLevelMtls:
    9091:          # queue-proxy metrics (knative.dataPlane)
      mode: PERMISSIVE
```

Port-level settings only take effect with a workload selector. The Knative control plane in
`knative-serving` is not sidecar-injected by default.

## DCGM metrics

The NVIDIA DCGM exporter runs on every NVIDIA GPU node when `dcgmExporter.enabled` is true,
the default. It collects 51 DCGM fields and the driver version label. The list is
`$metricsConfig` in `templates/linux/dcgm-exporter-daemonset.yaml`.

## Windows Support
CloudWatch DaemonSet on Windows is officially supported only for containerd runtime.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.

