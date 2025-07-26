for playground_id in $(labctl playground list -q); do
  labctl playground stop $playground_id
done
