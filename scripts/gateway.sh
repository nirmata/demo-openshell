#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kubectl nc
cluster_exists || die "cluster '${CLUSTER_NAME}' not found; run ./scripts/setup.sh"
OPENSH="$(openshell_bin)" || die "OpenShell CLI not found; run ./scripts/install-cli.sh"

cert_dir="${XDG_CONFIG_HOME}/openshell/gateways/kind-openshell/mtls"
mkdir -p "${cert_dir}"
for item in 'ca.crt:ca.crt' 'tls.crt:tls.crt' 'tls.key:tls.key'; do
  key="${item%%:*}"; file="${item#*:}"
  k -n openshell get secret openshell-client-tls \
    -o "jsonpath={.data.${key//./\\.}}" | base64 -d > "${cert_dir}/${file}"
done

PORT_FORWARD_LOG=""
PORT_FORWARD_PID=""
cleanup() {
  trap - INT TERM EXIT
  if [ -n "${PORT_FORWARD_PID}" ]; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
  [ -z "${PORT_FORWARD_LOG}" ] || rm -f "${PORT_FORWARD_LOG}"
}
trap cleanup INT TERM EXIT

start_gateway_port_forward

"${OPENSH}" gateway remove kind-openshell >/dev/null 2>&1 || true
"${OPENSH}" gateway add "https://127.0.0.1:${GATEWAY_LOCAL_PORT}" \
  --name kind-openshell --local >/dev/null
"${OPENSH}" status
ensure_openshell_workspace "${OPENSH}"

info "gateway is available while this command remains running; Ctrl-C to stop"
wait "${PORT_FORWARD_PID}"
