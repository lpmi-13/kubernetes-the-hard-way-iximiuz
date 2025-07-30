export ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

envsubst < configs/encryption-config.yaml \
  > encryption-config.yaml

for host in controller-{1..3}; do
  scp -i ~/.ssh/kubernetes.ed25519 encryption-config.yaml root@${host}:~/
done
