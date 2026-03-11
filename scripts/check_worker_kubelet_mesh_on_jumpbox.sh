#!/usr/bin/env bash
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/kubernetes.ed25519}"

worker_cluster_index_for_name() {
  local worker_name="$1"
  local worker_number="${worker_name#worker-}"

  printf '%d\n' "$(( ((worker_number - 1) / 3) + 1 ))"
}

TARGET_HOSTS=("$@")
if [ "${#TARGET_HOSTS[@]}" -eq 0 ]; then
  TARGET_HOSTS=(worker-{1..9})
fi

declare -A WORKER_IPS=()

for worker in "${TARGET_HOSTS[@]}"; do
  worker_ip="$(ssh -i "${SSH_KEY}" root@"${worker}" "tailscale ip -4" | tr -d '\r\n')"
  if [ -z "${worker_ip}" ]; then
    echo "failed to resolve tailscale ip for ${worker}" >&2
    exit 2
  fi
  WORKER_IPS["${worker}"]="${worker_ip}"
done

failures=0

for source in "${TARGET_HOSTS[@]}"; do
  source_cluster="$(worker_cluster_index_for_name "${source}")"
  target_inventory=""

  for target in "${TARGET_HOSTS[@]}"; do
    [ "${target}" = "${source}" ] && continue
    if [ "$(worker_cluster_index_for_name "${target}")" -eq "${source_cluster}" ]; then
      continue
    fi
    target_inventory+="${target}"$'\t'"${WORKER_IPS[$target]}"$'\n'
  done

  [ -n "${target_inventory}" ] || continue

  if ! validation_output="$(
    ssh -i "${SSH_KEY}" root@"${source}" <<EOF
set -eu
SOURCE_NAME='${source}'

while IFS=\$'\t' read -r target_name target_ip; do
  [ -n "\${target_name}" ] || continue
  [ -n "\${target_ip}" ] || continue

  curl_output="\$(curl -sk --max-time 3 -o /dev/null -w 'http_code=%{http_code}' "https://\${target_ip}:10250/healthz" 2>&1 || true)"
  http_code="\$(printf '%s\n' "\${curl_output}" | sed -n 's/.*http_code=\([0-9][0-9][0-9]\).*/\1/p' | tail -n 1)"

  case "\${http_code}" in
    200|401|403)
      continue
      ;;
  esac

  curl_summary="\$(printf '%s\n' "\${curl_output}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ \$//')"
  printf '%s\t%s\tcurl-failed\t%s\n' "\${SOURCE_NAME}" "\${target_name}" "\${curl_summary}"
done <<'TARGETS'
${target_inventory}
TARGETS
EOF
  )"; then
    ssh_error_summary="$(printf '%s\n' "${validation_output:-ssh failed}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    while IFS=$'\t' read -r target_name _; do
      [ -n "${target_name}" ] || continue
      printf '%s\t%s\tssh-error\t%s\n' "${source}" "${target_name}" "${ssh_error_summary}"
      failures=$((failures + 1))
    done <<< "${target_inventory}"
    continue
  fi

  while IFS=$'\t' read -r source_name target_name status detail; do
    [ -n "${source_name}" ] || continue
    [ -n "${target_name}" ] || continue
    printf '%s\t%s\t%s\t%s\n' "${source_name}" "${target_name}" "${status}" "${detail}"
    failures=$((failures + 1))
  done <<< "${validation_output}"
done

if [ "${failures}" -gt 0 ]; then
  exit 1
fi
