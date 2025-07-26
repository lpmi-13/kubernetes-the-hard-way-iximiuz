JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./downloads.txt $JUMPBOX_PLAYGROUND_ID:~/downloads.txt

cat scripts/setup_jumpbox.sh | labctl ssh $JUMPBOX_PLAYGROUND_ID
