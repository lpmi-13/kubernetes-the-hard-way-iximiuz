JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./scripts/generate_kubernetes_config.sh $JUMPBOX_PLAYGROUND_ID:~/generate_kubernetes_config.sh

labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/generate_kubernetes_config.sh"
