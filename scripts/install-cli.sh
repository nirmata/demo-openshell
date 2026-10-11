#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tools curl tar

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) asset="openshell-aarch64-apple-darwin.tar.gz" ;;
  Linux-x86_64) asset="openshell-x86_64-unknown-linux-musl.tar.gz" ;;
  Linux-aarch64|Linux-arm64) asset="openshell-aarch64-unknown-linux-musl.tar.gz" ;;
  *) die "unsupported platform: $(uname -s)-$(uname -m); use the official OpenShell installer" ;;
esac

version="v${OPENSHELL_VERSION#v}"
base_url="https://github.com/NVIDIA/OpenShell/releases/download/${version}"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

step "Installing OpenShell CLI ${OPENSHELL_VERSION} locally"
curl -fLsS --retry 3 -o "${tmp_dir}/${asset}" "${base_url}/${asset}"
curl -fLsS --retry 3 -o "${tmp_dir}/checksums" "${base_url}/openshell-checksums-sha256.txt"
(cd "${tmp_dir}" && grep "  ${asset}$" checksums | shasum -a 256 -c -)
mkdir -p "${REPO_ROOT}/.tools/bin"
tar -xzf "${tmp_dir}/${asset}" -C "${tmp_dir}"
cli_path="$(find "${tmp_dir}" -type f -name openshell -perm -u+x | head -1)"
[ -n "${cli_path}" ] || die "the release archive did not contain an openshell executable"
cp "${cli_path}" "${REPO_ROOT}/.tools/bin/openshell"
chmod +x "${REPO_ROOT}/.tools/bin/openshell"
ok "installed $("${REPO_ROOT}/.tools/bin/openshell" --version)"
