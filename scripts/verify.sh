#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kind kubectl helm
cluster_exists || die "cluster '${CLUSTER_NAME}' not found"

step "Cluster"
k get nodes
[ "$(k get nodes --no-headers | grep -c ' Ready')" -ge 2 ] || die "not all kind nodes are ready"

step "Controllers"
k -n kube-system rollout status daemonset/cilium --timeout=2m
k -n agent-sandbox-system rollout status deployment/agent-sandbox-controller --timeout=2m
k -n openshell rollout status statefulset/openshell --timeout=2m
k -n kyverno wait --for=condition=Available deployment --all --timeout=2m >/dev/null

step "OpenShell resources"
k get crd sandboxes.agents.x-k8s.io >/dev/null
k -n openshell get networkpolicy openshell-sandbox-ssh >/dev/null
h status openshell -n openshell >/dev/null
for policy in \
  enforce-sandbox-resource-bounds \
  enforce-sandbox-pod-security \
  protect-sandbox-credentials \
  enforce-sandbox-image-hygiene \
  restrict-openshell-rbac \
  verify-openshell-network-boundary; do
  [ "$(k get validatingpolicy "${policy}" -o jsonpath='{.status.conditionStatus.ready}')" = true ] ||
    die "Kyverno policy ${policy} is not ready"
done
[ "$(k get mutatingpolicy default-sandbox-resources -o jsonpath='{.status.conditionStatus.ready}')" = true ] ||
  die "Kyverno policy default-sandbox-resources is not ready"
ok "OpenShell and Kyverno are healthy on kind-${CLUSTER_NAME}"
