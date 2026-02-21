for playground_id in $(labctl playground list -q); do
  labctl playground destroy $playground_id
done

rm kubernetes.ed25519*
