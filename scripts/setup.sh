#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<EOF
Usage: scripts/setup.sh

Creates or updates the kind cluster '${CLUSTER_NAME}' and installs Cilium,
Agent Sandbox ${AGENT_SANDBOX_VERSION}, and OpenShell ${OPENSHELL_VERSION}.

Environment overrides: CLUSTER_NAME, KIND_NODE_IMAGE, CILIUM_VERSION,
AGENT_SANDBOX_VERSION, OPENSHELL_VERSION, OPENSHELL_GATEWAY_DIGEST,
OPENSHELL_SANDBOX_DIGEST, OPENSHELL_SUPERVISOR_DIGEST, OPENSHELL_WORKSPACE
EOF
  exit 0
fi
[ $# -eq 0 ] || die "unknown argument: $1"

require_tools docker kind kubectl helm
docker info >/dev/null 2>&1 || die "Docker does not appear to be running"

step "1/7 kind cluster '${CLUSTER_NAME}'"
if cluster_exists; then
  ok "cluster already exists"
else
  kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" \
    --config "${REPO_ROOT}/config/kind/kind-config.yaml"
  ok "cluster created"
fi

step "2/7 Cilium ${CILIUM_VERSION}"
if h status cilium -n kube-system >/dev/null 2>&1; then
  ok "Cilium already installed"
else
  helm repo add cilium https://helm.cilium.io/ --force-update >/dev/null
  helm repo update cilium >/dev/null
  h upgrade --install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=false \
    --set operator.replicas=1 \
    --set hubble.enabled=false \
    --wait --timeout 10m
fi
k -n kube-system rollout status daemonset/cilium --timeout=5m
k -n kube-system rollout status deployment/cilium-operator --timeout=5m
ok "Cilium is enforcing Kubernetes NetworkPolicy"

step "3/7 Agent Sandbox ${AGENT_SANDBOX_VERSION}"
k apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/${AGENT_SANDBOX_VERSION}/sandbox.yaml"
k -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=5m
ok "Agent Sandbox controller ready"

step "4/7 OpenShell ${OPENSHELL_VERSION}"
k get namespace openshell >/dev/null 2>&1 || k create namespace openshell
# Remove the retired identity-based network policy before Helm reconciles the
# OpenShell-owned fences. The replacement validates fence contents instead.
if k get crd validatingpolicies.policies.kyverno.io >/dev/null 2>&1; then
  k delete validatingpolicy protect-openshell-network-fences --ignore-not-found >/dev/null
fi
h upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version "${OPENSHELL_VERSION}" \
  --namespace openshell \
  --set server.telemetryEnabled=false \
  --set server.auth.allowUnauthenticatedUsers=true \
  --set server.drivers.kubernetes.workspaceMode=shared \
  --set gateway.image.digest="${OPENSHELL_GATEWAY_DIGEST}" \
  --set sandboxRuntime.image.digest="${OPENSHELL_SANDBOX_DIGEST}" \
  --set supervisor.image.digest="${OPENSHELL_SUPERVISOR_DIGEST}" \
  --wait --timeout 10m
k -n openshell rollout status statefulset/openshell --timeout=5m
ok "OpenShell gateway ready"

step "5/7 Kyverno (chart ${KYVERNO_CHART_VERSION})"
if h status kyverno -n kyverno >/dev/null 2>&1; then
  ok "Kyverno already installed"
else
  helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update >/dev/null
  helm repo update kyverno >/dev/null
  h upgrade --install kyverno kyverno/kyverno \
    --version "${KYVERNO_CHART_VERSION}" \
    --namespace kyverno --create-namespace \
    --set admissionController.replicas=1 \
    --set backgroundController.replicas=1 \
    --set reportsController.replicas=1 \
    --set cleanupController.replicas=1 \
    --wait --timeout 10m
fi
k -n kyverno wait --for=condition=Available deployment --all --timeout=5m >/dev/null
ok "Kyverno ready"

step "6/7 OpenShell guardrails"
k apply -f "${REPO_ROOT}/config/kyverno/rbac/"
k delete validatingpolicy \
  require-openshell-provisioning \
  harden-openshell-sandboxes \
  protect-openshell-network-fences \
  --ignore-not-found >/dev/null
k apply -f "${REPO_ROOT}/config/kyverno/policies/"
for policy in \
  enforce-sandbox-resource-bounds \
  enforce-sandbox-pod-security \
  protect-sandbox-credentials \
  enforce-sandbox-image-hygiene \
  restrict-openshell-rbac \
  verify-openshell-network-boundary; do
  k wait --for='jsonpath={.status.conditionStatus.ready}=true' \
    "validatingpolicy/${policy}" --timeout=2m >/dev/null
done
k wait --for='jsonpath={.status.conditionStatus.ready}=true' \
  mutatingpolicy/default-sandbox-resources --timeout=2m >/dev/null
k get validatingpolicy,mutatingpolicy
ok "Kyverno policies ready"

step "7/7 Smoke checks"
k get pods -n agent-sandbox-system
k get pods -n openshell
k get networkpolicy -n openshell
ok "cluster installation verified"

cat <<EOF

    Cluster:  ${CLUSTER_NAME}
    Context:  $(kube_context)
    Workspace: ${OPENSHELL_WORKSPACE}

    Install the demo-local CLI, then run the walkthrough:
      ./scripts/install-cli.sh
      ./scripts/demo.sh
      ./scripts/kyverno-demo.sh

    Tear down everything with:
      ./scripts/cleanup.sh
EOF
