#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/kubernetes-events.sh [OPTIONS]

Watch new Kubernetes events and print a compact, color-coded timeline. The
watch starts at the current resource version, so existing event history is not
replayed when the script starts.

Options:
  -n, --namespace NAME  Watch one namespace instead of the whole cluster
  -w, --warnings-only   Show only Warning events
  -a, --all-updates     Show repeated updates to the same Event object
      --no-color        Disable terminal colors
  -h, --help            Show this help

Examples:
  ./scripts/kubernetes-events.sh
  ./scripts/kubernetes-events.sh --namespace openshell
  ./scripts/kubernetes-events.sh --warnings-only
EOF
}

namespace=""
warnings_only=false
show_updates=false
color=true

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)
      [ $# -ge 2 ] || die "$1 requires a namespace"
      namespace="$2"
      shift
      ;;
    -w|--warnings-only) warnings_only=true ;;
    -a|--all-updates) show_updates=true ;;
    --no-color) color=false ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

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

if [ "${warnings_only}" = true ]; then
  warnings_value=1
else
  warnings_value=0
fi
if [ "${show_updates}" = true ]; then
  updates_value=1
else
  updates_value=0
fi

format_events() {
  awk \
    -v warnings_only="${warnings_value}" \
    -v show_updates="${updates_value}" \
    -v dim="${c_dim}" \
    -v blue="${c_blue}" \
    -v green="${c_green}" \
    -v yellow="${c_yellow}" \
    -v red="${c_red}" \
    -v off="${c_off}" '
    BEGIN {
      printf "%s%-12s  %-7s  %-16s  %-40s  %-22s  %s%s\n", dim, "TIME (UTC)", "TYPE", "NAMESPACE", "OBJECT", "REASON", "MESSAGE", off
    }

    NF >= 10 {
      watch_type = $1
      timestamp = $2
      if (timestamp == "<none>" || timestamp == "<nil>") timestamp = $3
      event_type = $4
      namespace = $5
      object = $6 "/" $7
      reason = $8
      uid = $9
      count = $10
      message = ""
      for (field = 11; field <= NF; field++) {
        message = message (message == "" ? "" : " ") $field
      }

      if (warnings_only && event_type != "Warning") next
      if (!show_updates && uid != "" && seen[uid]++) next

      if (timestamp ~ /^[0-9][0-9][0-9][0-9]-/) {
        timestamp = substr(timestamp, 12, 12)
        sub(/\..*$/, "", timestamp)
      }
      if (timestamp == "") timestamp = "-"

      state = event_type
      tone = blue
      if (event_type == "Normal") { state = "OK"; tone = green }
      if (event_type == "Warning") { state = "WARN"; tone = red }
      if (watch_type == "DELETED") { state = "DELETE"; tone = dim }
      if (count + 0 > 1) message = message " (x" count ")"

      printf "%s%-12s%s  %s%-7s%s  %-16s  %-40s  %-22s  %s\n", dim, timestamp, off, tone, state, off, namespace, object, reason, message
      fflush()
    }
  '
}

require_tools kubectl
cluster_exists || die "cluster '${CLUSTER_NAME}' not found; run ./scripts/setup.sh"

kubectl_args=(
  --context "$(kube_context)"
  get events
  --watch-only
  --output-watch-events
)
if [ -n "${namespace}" ]; then
  kubectl_args+=(-n "${namespace}")
else
  kubectl_args+=(--all-namespaces)
fi

# Keep the message last because it is the only selected field that may contain
# whitespace. kubectl streams custom-column rows immediately during a watch;
# Go-template and JSONPath printers buffer output until the watch closes.
event_columns='WATCH:.type,LAST:.object.lastTimestamp,CREATED:.object.metadata.creationTimestamp,TYPE:.object.type,NAMESPACE:.object.metadata.namespace,KIND:.object.involvedObject.kind,NAME:.object.involvedObject.name,REASON:.object.reason,UID:.object.metadata.uid,COUNT:.object.count,MESSAGE:.object.message'

kubectl "${kubectl_args[@]}" --no-headers -o "custom-columns=${event_columns}" | format_events
