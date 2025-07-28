JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./downloads.txt $JUMPBOX_PLAYGROUND_ID:~/downloads.txt

cat scripts/setup_jumpbox.sh | labctl ssh $JUMPBOX_PLAYGROUND_ID

rm kubernetes.ed25519*

# we also need to distribute ssh keys so that we can copy stuff from the jumpbox to the other nodes
ssh-keygen -t ed25519 -C "laborant@jumpbox" -o -a 100 -f kubernetes.ed25519 -N ""

labctl cp ./kubernetes.ed25519 $JUMPBOX_PLAYGROUND_ID:~/.ssh/

# now we copy in the public key into all the machines
for playground_id in $(labctl playground list -q); do
  for machine_name in $(labctl playground machines $playground_id | sed '1d'); do
    # if it's the jumpbox, we put it directly in the ~/.ssh directory so we can access other machines from there
    if [[ $playground_id == $JUMPBOX_PLAYGROUND_ID ]]; then
      echo "adding ssh key to the jumpbox"
      labctl cp ./kubernetes.ed25519.pub $playground_id:~/.ssh/ --machine $machine_name
    else
      echo "adding the jumpbox ssh key to the authorized_keys for $machine_name"
      labctl ssh $playground_id --machine $machine_name -- "chmod 600 ~/.ssh/authorized_keys"
      labctl ssh $playground_id --machine $machine_name -- "printf \"\n\" >> ~/.ssh/authorized_keys"
      cat ./kubernetes.ed25519.pub | labctl ssh $playground_id --machine $machine_name -- "cat >> ~/.ssh/authorized_keys"
      labctl ssh $playground_id --machine $machine_name -- "chmod 400 ~/.ssh/authorized_keys"
    fi
  done
done
