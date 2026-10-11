#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kubectl ssh awk
cluster_exists || die "cluster '${CLUSTER_NAME}' not found; run ./scripts/setup.sh"
OPENSH="$(openshell_bin)" || die "OpenShell CLI not found; run ./scripts/install-cli.sh"

SANDBOX_NAME="${SANDBOX_NAME:-policy-demo}"
SSH_CONFIG="$(mktemp)"
PORT_FORWARD_LOG=""
PORT_FORWARD_PID=""

cleanup() {
  set +e
  "${OPENSH}" sandbox delete "${SANDBOX_NAME}" --workspace "${OPENSHELL_WORKSPACE}" >/dev/null 2>&1
  if [ -n "${PORT_FORWARD_PID}" ]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1
  fi
  rm -f "${SSH_CONFIG}" "${PORT_FORWARD_LOG}"
}
trap cleanup EXIT

step "Connecting the CLI to OpenShell on kind-${CLUSTER_NAME}"
mkdir -p "${XDG_CONFIG_HOME}/openshell/gateways/kind-openshell/mtls"
for item in 'ca.crt:ca.crt' 'tls.crt:tls.crt' 'tls.key:tls.key'; do
  key="${item%%:*}"; file="${item#*:}"
  k -n openshell get secret openshell-client-tls \
    -o "jsonpath={.data.${key//./\\.}}" | base64 -d \
    > "${XDG_CONFIG_HOME}/openshell/gateways/kind-openshell/mtls/${file}"
done

start_gateway_port_forward

"${OPENSH}" gateway remove kind-openshell >/dev/null 2>&1 || true
"${OPENSH}" gateway add "https://127.0.0.1:${GATEWAY_LOCAL_PORT}" \
  --name kind-openshell --local >/dev/null
"${OPENSH}" status
ensure_openshell_workspace "${OPENSH}"

step "1/4 Create a sandbox with default-deny networking"
"${OPENSH}" sandbox delete "${SANDBOX_NAME}" --workspace "${OPENSHELL_WORKSPACE}" >/dev/null 2>&1 || true
"${OPENSH}" sandbox create --name "${SANDBOX_NAME}" --from "${DEMO_IMAGE}" \
  --workspace "${OPENSHELL_WORKSPACE}" --no-auto-providers --no-tty -- echo ready
"${OPENSH}" sandbox ssh-config "${SANDBOX_NAME}" --workspace "${OPENSHELL_WORKSPACE}" > "${SSH_CONFIG}"
SSH_HOST="$(awk '/^Host / { print $2; exit }' "${SSH_CONFIG}")"
for _ in $(seq 1 30); do
  ssh -F "${SSH_CONFIG}" "${SSH_HOST}" true >/dev/null 2>&1 && break
  sleep 2
done
ssh -F "${SSH_CONFIG}" "${SSH_HOST}" true >/dev/null 2>&1 || die "sandbox SSH did not become ready"

step "2/4 Default deny blocks api.github.com"
if ssh -F "${SSH_CONFIG}" "${SSH_HOST}" curl -sSf --max-time 5 https://api.github.com/zen; then
  die "expected the request to be denied"
fi
ok "request denied"

step "3/4 Apply a read-only L7 policy without restarting"
"${OPENSH}" policy update "${SANDBOX_NAME}" \
  --workspace "${OPENSHELL_WORKSPACE}" \
  --rule-name github_api \
  --binary /usr/bin/curl \
  --add-endpoint api.github.com:443:read-only:rest:enforce \
  --wait
zen="$(ssh -F "${SSH_CONFIG}" "${SSH_HOST}" curl -sSf --max-time 10 https://api.github.com/zen)"
ok "GET allowed: ${zen}"

response="$(ssh -F "${SSH_CONFIG}" "${SSH_HOST}" \
  'curl -sS --max-time 10 -X POST -d title=blocked https://api.github.com/repos/octocat/hello-world/issues')"
case "${response}" in
  *policy_denied*) ok "POST blocked by the read-only policy" ;;
  *) die "expected an L7 policy denial, got: ${response}" ;;
esac

step "4/4 Audit trail"
sleep 2
"${OPENSH}" logs "${SANDBOX_NAME}" --workspace "${OPENSHELL_WORKSPACE}" --since 5m --source sandbox -n 100 | \
  grep -E '(NET|HTTP):[A-Z]+ .*(ALLOWED|DENIED)' || warn "policy events have not reached the log stream yet"
ok "demo complete; sandbox will be deleted"
