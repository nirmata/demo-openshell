#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/operations.sh [OPTIONS] [LOG_FILE|-]

Print a compact timeline of OpenShell gateway operations. With no LOG_FILE,
logs are read from statefulset/openshell in the demo cluster.

Options:
  -f, --follow       Stream new log entries
      --since TIME   Only request logs newer than TIME (for example 10m or 1h)
  -a, --all          Include reconciliation and credential-refresh housekeeping
      --no-color     Disable terminal colors
  -h, --help         Show this help

Examples:
  ./scripts/operations.sh --since 10m
  ./scripts/operations.sh --follow
  kubectl -n openshell logs statefulset/openshell | ./scripts/operations.sh -
  ./scripts/operations.sh gateway.log
EOF
}

follow=false
since=""
show_all=false
color=true
input=""

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--follow) follow=true ;;
    --since)
      [ $# -ge 2 ] || die "--since requires a value"
      since="$2"
      shift
      ;;
    -a|--all) show_all=true ;;
    --no-color) color=false ;;
    -h|--help) usage; exit 0 ;;
    -) [ -z "${input}" ] || die "only one input may be specified"; input="-" ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "${input}" ] || die "only one input may be specified"; input="$1" ;;
  esac
  shift
done

if [ -n "${input}" ] && { [ "${follow}" = true ] || [ -n "${since}" ]; }; then
  die "--follow and --since apply only when reading logs from Kubernetes"
fi

if [ "${color}" = true ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_dim=$'\033[2m'
  c_blue=$'\033[34m'
  c_green=$'\033[32m'
  c_yellow=$'\033[33m'
  c_red=$'\033[31m'
  c_off=$'\033[0m'
else
  c_dim=""; c_blue=""; c_green=""; c_yellow=""; c_red=""; c_off=""
fi

parse_logs() {
  if [ "${show_all}" = true ]; then
    show_all_value=1
  else
    show_all_value=0
  fi
  awk \
    -v show_all="${show_all_value}" \
    -v dim="${c_dim}" \
    -v blue="${c_blue}" \
    -v green="${c_green}" \
    -v yellow="${c_yellow}" \
    -v red="${c_red}" \
    -v off="${c_off}" '
    function value(key,    pattern, found) {
      pattern = key "=\"[^\"]+\""
      if (match(raw, pattern)) {
        found = substr(raw, RSTART + length(key) + 2, RLENGTH - length(key) - 3)
        return found
      }
      pattern = key "=[^ }]+"
      if (match(raw, pattern)) {
        found = substr(raw, RSTART + length(key) + 1, RLENGTH - length(key) - 1)
        return found
      }
      return ""
    }

    function short_id(id) {
      if (length(id) > 12) return substr(id, 1, 8) ".."
      return id
    }

    BEGIN {
      printf "%s%-23s  %-7s  %-24s  %-17s  %s%s\n", dim, "TIME", "STATE", "OPERATION", "SANDBOX", "DETAIL", off
    }

    {
      raw = $0
      # OpenShell enables tracing-subscriber colors in its container logs.
      # Strip SGR sequences before matching fields, then add our own colors.
      gsub(sprintf("%c", 27) "\\[[0-9;]*m", "", raw)
      if (raw !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/) next

      split(raw, words, /[[:space:]]+/)
      timestamp = substr(words[1], 1, 23)
      sub(/T/, " ", timestamp)
      level = words[2]

      operation = ""
      path = value("path")
      if (path != "") {
        operation = path
        sub(/^.*\//, "", operation)
      }

      sandbox = value("sandbox_name")
      if (sandbox == "") sandbox = value("sandbox_id")
      if (sandbox == "") sandbox = value("sandbox.id")
      sandbox = short_id(sandbox)

      parts = split(raw, segments, ": ")
      detail = segments[parts]

      state = "INFO"
      tone = blue
      if (level == "WARN") { state = "WARN"; tone = yellow }
      if (level == "ERROR" || raw ~ /otel.status_code="ERROR"/) { state = "ERROR"; tone = red }

      if (detail ~ /completed successfully|Sandbox deleted from Kubernetes/) {
        state = "OK"; tone = green
      } else if (detail ~ /^Deleting sandbox|^Creating sandbox|^Stopping sandbox|^Starting sandbox/) {
        state = "START"; tone = yellow
      } else if (detail ~ /^response status=/) {
        status = value("status")
        if (status == "") status = value("http.response.status_code")
        latency = value("latency_ms")
        grpc_status = value("rpc.grpc.status_code")
        detail = "HTTP " status
        if (latency != "") detail = detail " · " latency " ms"
        if (grpc_status != "" && grpc_status != "0") {
          state = "ERROR"; tone = red
          detail = detail " · gRPC " grpc_status
        } else {
          state = "OK"; tone = green
        }
      } else if (raw ~ /supervisor session: (stream closed|ended)/) {
        state = "CLOSE"; tone = dim
      }

      if (operation == "") {
        if (detail ~ /[Dd]elet.*sandbox/) operation = "DeleteSandbox"
        else if (detail ~ /[Cc]reat.*sandbox/) operation = "CreateSandbox"
        else if (raw ~ /supervisor_session|supervisor session/) operation = "SupervisorSession"
        else if (detail ~ /Listing sandboxes/) operation = "ReconcileSandboxes"
        else if (detail ~ /credential refresh/) operation = "RefreshCredentials"
        else operation = "Gateway"
      }

      housekeeping = operation == "ReconcileSandboxes" || operation == "RefreshCredentials"
      if (!show_all && housekeeping) next

      if (sandbox == "") sandbox = "-"
      printf "%s%-23s%s  %s%-7s%s  %-24s  %-17s  %s\n", dim, timestamp, off, tone, state, off, operation, sandbox, detail
      fflush()
    }
  '
}

if [ "${input}" = "-" ]; then
  parse_logs
elif [ -n "${input}" ]; then
  [ -r "${input}" ] || die "cannot read log file: ${input}"
  parse_logs < "${input}"
else
  require_tools kubectl
  cluster_exists || die "cluster '${CLUSTER_NAME}' not found; run ./scripts/setup.sh"
  kubectl_args=(--context "$(kube_context)" -n openshell logs statefulset/openshell)
  [ "${follow}" = false ] || kubectl_args+=(--follow)
  [ -z "${since}" ] || kubectl_args+=(--since "${since}")
  kubectl "${kubectl_args[@]}" | parse_logs
fi
