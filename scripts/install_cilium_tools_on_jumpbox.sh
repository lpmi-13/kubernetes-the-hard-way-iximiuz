#!/usr/bin/env bash
set -euo pipefail

CILIUM_CLI_VERSION="v0.18.9"
HELM_VERSION="v3.17.0"

has_working_binary() {
  local binary_path="$1"
  shift

  if [ ! -x "${binary_path}" ]; then
    return 1
  fi

  "$@" >/dev/null 2>&1
}

install_tarball_binary() {
  local name="$1"
  local url="$2"
  local archive_member="$3"
  local target_path="$4"
  local temp_dir
  local extract_dir
  local tarball_path
  local target_dir
  local target_tmp
  local rc=0

  temp_dir="$(mktemp -d)"
  extract_dir="${temp_dir}/extract"
  tarball_path="${temp_dir}/${name}.tar.gz"
  target_dir="$(dirname "${target_path}")"
  target_tmp="${target_dir}/.${name}.tmp.$$"
  mkdir -p "${extract_dir}"

  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120 -o "${tarball_path}" "${url}" || rc=$?
  if [ "${rc}" -eq 0 ]; then
    tar xzf "${tarball_path}" -C "${extract_dir}" "${archive_member}" || rc=$?
  fi
  if [ "${rc}" -eq 0 ]; then
    install -m 0755 "${extract_dir}/${archive_member}" "${target_tmp}" || rc=$?
  fi
  if [ "${rc}" -eq 0 ]; then
    mv -f "${target_tmp}" "${target_path}" || rc=$?
  fi

  rm -rf "${temp_dir}"
  rm -f "${target_tmp}"

  if [ "${rc}" -ne 0 ]; then
    return "${rc}"
  fi
}

# Install Cilium CLI
if has_working_binary /usr/local/bin/cilium /usr/local/bin/cilium version --client; then
  echo "[cilium] Cilium CLI already installed"
else
  echo "[cilium] installing Cilium CLI ${CILIUM_CLI_VERSION}"
  install_tarball_binary \
    "cilium" \
    "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz" \
    "cilium" \
    "/usr/local/bin/cilium"
fi

# Install Helm
if has_working_binary /usr/local/bin/helm /usr/local/bin/helm version --short; then
  echo "[helm] Helm already installed"
else
  echo "[helm] installing Helm ${HELM_VERSION}"
  install_tarball_binary \
    "helm" \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    "linux-amd64/helm" \
    "/usr/local/bin/helm"
fi

cilium version --client
helm version --short
