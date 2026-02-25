# Cleanup

In this lab you will delete the compute resources created during the tutorial.

## Destroy Playgrounds

List playgrounds and destroy each one:

```sh
for playground_id in $(labctl playground list -q); do
  echo "Destroying playground ${playground_id}"
  labctl playground destroy "${playground_id}"
done
```

## Remove Local SSH Keys

```sh
rm -f ./kubernetes.ed25519 ./kubernetes.ed25519.pub
```

## Remove Tailscale Devices (Optional but Recommended)

If you used Tailscale OAuth for enrollment, you can remove devices via the API. The commands below delete devices that match current lab machine names and the `tag:kthw` tag.

```sh
source .env

TS_TAGS=${TS_TAGS:-tag:kthw}
MACHINE_NAMES=$(labctl playground list -o json | jq -r '(. // [])[]? | (.machines // [])[].name // empty')

ACCESS_TOKEN=$(curl -sS -u "${TS_API_CLIENT_ID}:${TS_API_CLIENT_SECRET}" \
  -d grant_type=client_credentials \
  https://api.tailscale.com/api/v2/oauth/token | jq -r '.access_token')

DEVICES_JSON=$(curl -sS -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  https://api.tailscale.com/api/v2/tailnet/-/devices)

for name in ${MACHINE_NAMES}; do
  device_id=$(echo "${DEVICES_JSON}" | jq -r --arg name "${name}" --arg tag "${TS_TAGS}" '
    .devices[] | select((.name | split(".")[0]) == $name) | select((.tags // []) | index($tag)) | .id' | head -n 1)
  if [ -n "${device_id}" ] && [ "${device_id}" != "null" ]; then
    echo "Deleting Tailscale device ${name} (${device_id})"
    curl -sS -X DELETE -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "https://api.tailscale.com/api/v2/device/${device_id}" >/dev/null
  fi
done
```
