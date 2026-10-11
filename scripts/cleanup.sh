#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools kind
if cluster_exists; then
  step "Deleting kind cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}"
  ok "cluster deleted"
else
  ok "cluster '${CLUSTER_NAME}' does not exist"
fi

