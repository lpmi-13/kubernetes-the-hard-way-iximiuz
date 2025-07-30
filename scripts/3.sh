JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./downloads.txt $JUMPBOX_PLAYGROUND_ID:~/downloads.txt

# this is for convenience so we can skip the host key checking
labctl cp ./scripts/jumpbox_ssh_config $JUMPBOX_PLAYGROUND_ID:~/.ssh/config

labctl cp -r ./configs $JUMPBOX_PLAYGROUND_ID:~/configs

cat scripts/setup_jumpbox.sh | labctl ssh $JUMPBOX_PLAYGROUND_ID

rm kubernetes.ed25519*

# we also need to distribute ssh keys so that we can copy stuff from the jumpbox to the other nodes
ssh-keygen -t ed25519 -C "root@jumpbox" -o -a 100 -f kubernetes.ed25519 -N ""

labctl cp ./kubernetes.ed25519 $JUMPBOX_PLAYGROUND_ID:~/.ssh/

PUBLIC_KEY_VALUE=$(cat ./kubernetes.ed25519.pub | tr -d '\n')

# now we copy in the public key into all the machines
for playground_id in $(labctl playground list -q); do
  for machine_name in $(labctl playground machines $playground_id | sed '1d'); do
    # if it's the jumpbox, we put it directly in the ~/.ssh directory so we can access other machines from there
    if [[ $playground_id == $JUMPBOX_PLAYGROUND_ID ]]; then
      echo "adding ssh key to the jumpbox"
      labctl cp ./kubernetes.ed25519.pub $playground_id:~/.ssh/ --machine $machine_name
    else
      echo "adding the jumpbox ssh key to the authorized_keys for $machine_name"
      SCRIPT=$(sed "s|PUBLIC_KEY_VALUE|$(echo "$PUBLIC_KEY_VALUE" | sed 's/[&/\]/\\&/g')|" scripts/update_authorized_keys.sh)
      echo "$SCRIPT" | labctl ssh $playground_id --machine $machine_name
    fi
  done
done

# NB: WE ACTUALLY NEED TO WAIT TIL THE API SERVER IS RUNNING ON THE CONTROLLER NODES, SO DO THIS LATER
# install HAProxy on the load balancer machine in the controller cluster
# LOADBALANCER_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | .[].name == "load-balancer") | .id')
#
# cat scripts/install_haproxy.sh | labctl ssh $LOADBALANCER_PLAYGROUND_ID --machine "load-balancer"
