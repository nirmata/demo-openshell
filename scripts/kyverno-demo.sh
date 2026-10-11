#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kubectl nc
cluster_exists || die "cluster '${CLUSTER_NAME}' not found; run ./scripts/setup.sh"
OPENSH="$(openshell_bin)" || die "OpenShell CLI not found; run ./scripts/install-cli.sh"

SANDBOX_NAME="${SANDBOX_NAME:-kyverno-demo}"
SANDBOX_RESOURCE="default--${SANDBOX_NAME}"
PORT_FORWARD_LOG=""
PORT_FORWARD_PID=""
TEMP_FILES=()

cleanup() {
  set +e
  "${OPENSH}" sandbox delete "${SANDBOX_NAME}" >/dev/null 2>&1
  if [ -n "${PORT_FORWARD_PID}" ]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1
  fi
  [ -z "${PORT_FORWARD_LOG}" ] || rm -f "${PORT_FORWARD_LOG}"
  [ ${#TEMP_FILES[@]} -eq 0 ] || rm -f "${TEMP_FILES[@]}"
}
trap cleanup EXIT

expect_denied() {
  local description="$1" expected="$2"
  shift 2
  local output
  if output=$("$@" 2>&1); then
    warn "${description}: request unexpectedly succeeded"
    return 1
  fi
  case "${output}" in
    *"${expected}"*) ok "${description}"; printf '        %s\n' "${output}" ;;
    *) warn "${description}: wrong failure: ${output}"; return 1 ;;
  esac
}

new_temp() {
  local file
  file="$(mktemp)"
  TEMP_FILES+=("${file}")
  printf '%s\n' "${file}"
}

step "Act 1 — sandbox Pod Security"
pod_security_manifest="$(new_temp)"
cat >"${pod_security_manifest}" <<EOF
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: unsafe-privilege
  namespace: openshell
spec:
  podTemplate:
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: agent
          image: ${DEMO_IMAGE}
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            privileged: true
            capabilities: {drop: [ALL]}
EOF
expect_denied "privileged sandbox denied" "Every sandbox container must run as non-root" \
  kubectl --context "$(kube_context)" apply --dry-run=server -f "${pod_security_manifest}"

step "Act 2 — OpenShell RBAC cannot grow wildcards"
rbac_manifest="$(new_temp)"
cat >"${rbac_manifest}" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: openshell-wildcard-demo
  namespace: openshell
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
EOF
expect_denied "wildcard OpenShell Role denied" "OpenShell RBAC rules may not contain wildcards" \
  kubectl --context "$(kube_context)" apply --dry-run=server -f "${rbac_manifest}"

step "Act 3 — workload traffic cannot bypass its supervisor"
expect_denied "direct workload egress denied" "may not allow direct workload egress" \
  kubectl --context "$(kube_context)" -n openshell patch \
    networkpolicy openshell-sandbox-workloads --dry-run=server --type merge \
    -p '{"spec":{"egress":[{}]}}'

step "Act 4 — sandbox images must be immutable"
mutable_image_manifest="$(new_temp)"
cat >"${mutable_image_manifest}" <<'EOF'
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: mutable-image
  namespace: openshell
spec:
  podTemplate:
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: agent
          image: nicolaka/netshoot:v0.13
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
EOF
expect_denied "mutable image tag denied" "immutable sha256 digest" \
  kubectl --context "$(kube_context)" apply --dry-run=server -f "${mutable_image_manifest}"

step "Act 5 — workload resources are defaulted and bounded"
safe_manifest="$(new_temp)"
cat >"${safe_manifest}" <<EOF
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: safe-defaults
  namespace: openshell
spec:
  podTemplate:
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: agent
          image: ${DEMO_IMAGE}
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
EOF
defaulted_cpu="$(kubectl --context "$(kube_context)" apply --dry-run=server \
  -o 'jsonpath={.spec.podTemplate.spec.containers[0].resources.requests.cpu}' \
  -f "${safe_manifest}")"
[ "${defaulted_cpu}" = "100m" ] || die "expected a 100m default CPU request, got '${defaulted_cpu}'"
ok "missing resources defaulted to the production baseline"

oversized_manifest="$(new_temp)"
cat >"${oversized_manifest}" <<EOF
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: oversized-sandbox
  namespace: openshell
spec:
  podTemplate:
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: agent
          image: ${DEMO_IMAGE}
          resources:
            requests: {cpu: 100m, memory: 128Mi, ephemeral-storage: 256Mi}
            limits: {cpu: "8", memory: 16Gi, ephemeral-storage: 40Gi}
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
EOF
expect_denied "oversized sandbox denied" "may use at most 4 CPU" \
  kubectl --context "$(kube_context)" apply --dry-run=server -f "${oversized_manifest}"

step "Act 6 — raw Kubernetes credentials stay out of sandboxes"
credential_manifest="$(new_temp)"
cat >"${credential_manifest}" <<EOF
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata:
  name: raw-credentials
  namespace: openshell
spec:
  podTemplate:
    spec:
      automountServiceAccountToken: false
      securityContext:
        seccompProfile: {type: RuntimeDefault}
      containers:
        - name: agent
          image: ${DEMO_IMAGE}
          envFrom:
            - secretRef: {name: raw-api-credentials}
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities: {drop: [ALL]}
EOF
expect_denied "raw Secret injection denied" "Use OpenShell providers" \
  kubectl --context "$(kube_context)" apply --dry-run=server -f "${credential_manifest}"

step "Create a compliant sandbox through OpenShell"
cert_dir="${XDG_CONFIG_HOME}/openshell/gateways/kind-openshell/mtls"
mkdir -p "${cert_dir}"
for item in 'ca.crt:ca.crt' 'tls.crt:tls.crt' 'tls.key:tls.key'; do
  key="${item%%:*}"; file="${item#*:}"
  k -n openshell get secret openshell-client-tls \
    -o "jsonpath={.data.${key//./\\.}}" | base64 -d >"${cert_dir}/${file}"
done
start_gateway_port_forward
"${OPENSH}" gateway remove kind-openshell >/dev/null 2>&1 || true
"${OPENSH}" gateway add "https://127.0.0.1:${GATEWAY_LOCAL_PORT}" \
  --name kind-openshell --local >/dev/null
"${OPENSH}" sandbox delete "${SANDBOX_NAME}" >/dev/null 2>&1 || true
"${OPENSH}" sandbox create --name "${SANDBOX_NAME}" --from "${DEMO_IMAGE}" \
  --no-auto-providers --no-tty -- echo ready >/dev/null
k -n openshell wait --for='jsonpath={.status.conditions[?(@.type=="Ready")].status}=True' \
  "sandbox/${SANDBOX_RESOURCE}" --timeout=3m >/dev/null
[ "$(k -n openshell get "sandbox/${SANDBOX_RESOURCE}" \
  -o 'jsonpath={.spec.podTemplate.spec.containers[0].resources.requests.cpu}')" = "100m" ] ||
  die "OpenShell sandbox did not retain the Kyverno resource default"
ok "digest-pinned OpenShell sandbox admitted with secure defaults"

step "Result"
ok "Pod Security, RBAC, network, supply-chain, resource, and credential controls passed"
