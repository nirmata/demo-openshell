# shellcheck shell=bash

CLUSTER_NAME="${CLUSTER_NAME:-openshell}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.0}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-0.1.3}"
OPENSHELL_GATEWAY_DIGEST="${OPENSHELL_GATEWAY_DIGEST:-sha256:ea14aa4db0980fab4769fb6b5509ac42ae3dc8495e645b1ba1fe1ada49892fa6}"
OPENSHELL_SANDBOX_DIGEST="${OPENSHELL_SANDBOX_DIGEST:-sha256:2658534bfb3f1ebba4bb7792e9e875a0972edbe7ae5f58d807ae22c46844a2ac}"
OPENSHELL_SUPERVISOR_DIGEST="${OPENSHELL_SUPERVISOR_DIGEST:-sha256:4ab2b970cdb02c7518ba4ccbbadb4861ae9a8d0b8770e5b160697f0453b0a8e4}"
AGENT_SANDBOX_VERSION="${AGENT_SANDBOX_VERSION:-v1.0.5}"
KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-3.8.2}"
OPENSHELL_WORKSPACE="${OPENSHELL_WORKSPACE:-demo}"
# Leave empty to ask kubectl for an unused loopback port. Set OPENSHELL_PORT to
# force a stable port when integrating with other local tooling.
OPENSHELL_PORT="${OPENSHELL_PORT:-}"
DEMO_IMAGE="${DEMO_IMAGE:-nicolaka/netshoot@sha256:a20c2531bf35436ed3766cd6cfe89d352b050ccc4d7005ce6400adf97503da1b}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.state"
XDG_CONFIG_HOME="${STATE_DIR}/config"
export XDG_CONFIG_HOME

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _bold=$'\033[1m'; _blue=$'\033[34m'; _green=$'\033[32m'
  _yellow=$'\033[33m'; _red=$'\033[31m'; _off=$'\033[0m'
else
  _bold=""; _blue=""; _green=""; _yellow=""; _red=""; _off=""
fi

step() { printf '\n%s==> %s%s\n' "${_bold}${_blue}" "$*" "${_off}"; }
info() { printf '    %s\n' "$*"; }
ok() { printf '    %s✔%s %s\n' "${_green}" "${_off}" "$*"; }
warn() { printf '    %s!%s %s\n' "${_yellow}" "${_off}" "$*" >&2; }
die() { printf '\n%sERROR:%s %s\n' "${_red}" "${_off}" "$*" >&2; exit 1; }

require_tools() {
  local missing=() tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing required tool(s): ${missing[*]}"
}

kube_context() { echo "kind-${CLUSTER_NAME}"; }
k() { kubectl --context "$(kube_context)" "$@"; }
h() { helm --kube-context "$(kube_context)" "$@"; }
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; }

# Starts a background port-forward and exports its PID, log path, and selected
# local port through PORT_FORWARD_PID, PORT_FORWARD_LOG, and GATEWAY_LOCAL_PORT.
start_gateway_port_forward() {
  local local_binding=":8080"
  [ -z "${OPENSHELL_PORT}" ] || local_binding="${OPENSHELL_PORT}:8080"

  PORT_FORWARD_LOG="$(mktemp)"
  kubectl --context "$(kube_context)" -n openshell \
    port-forward --address 127.0.0.1 service/openshell "${local_binding}" \
    >"${PORT_FORWARD_LOG}" 2>&1 &
  PORT_FORWARD_PID=$!
  GATEWAY_LOCAL_PORT=""

  for _ in $(seq 1 40); do
    if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
      die "port-forward failed: $(tail -1 "${PORT_FORWARD_LOG}")"
    fi
    GATEWAY_LOCAL_PORT="$(sed -n 's/.*127\.0\.0\.1:\([0-9][0-9]*\) -> 8080.*/\1/p' "${PORT_FORWARD_LOG}" | head -1)"
    [ -z "${GATEWAY_LOCAL_PORT}" ] || break
    sleep 0.25
  done

  [ -n "${GATEWAY_LOCAL_PORT}" ] || die "could not determine the gateway port: $(tail -1 "${PORT_FORWARD_LOG}")"
  ok "gateway forwarded to https://127.0.0.1:${GATEWAY_LOCAL_PORT}"
}

openshell_bin() {
  if [ -x "${REPO_ROOT}/.tools/bin/openshell" ]; then
    echo "${REPO_ROOT}/.tools/bin/openshell"
  elif command -v openshell >/dev/null 2>&1; then
    command -v openshell
  else
    return 1
  fi
}

ensure_openshell_workspace() {
  local opensh="$1"
  if "${opensh}" workspace get "${OPENSHELL_WORKSPACE}" >/dev/null 2>&1; then
    ok "OpenShell workspace '${OPENSHELL_WORKSPACE}' is ready"
  else
    "${opensh}" workspace create --name "${OPENSHELL_WORKSPACE}" >/dev/null
    ok "created OpenShell workspace '${OPENSHELL_WORKSPACE}'"
  fi
}
