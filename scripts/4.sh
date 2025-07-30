JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./ca.conf $JUMPBOX_PLAYGROUND_ID:~/ca.conf

labctl cp ./scripts/generate_certs.sh $JUMPBOX_PLAYGROUND_ID:~/generate_certs.sh

labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/generate_certs.sh"
