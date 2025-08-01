JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./downloads.txt $JUMPBOX_PLAYGROUND_ID:~/downloads.txt

# this is for convenience so we can skip the host key checking
labctl cp ./scripts/jumpbox_ssh_config $JUMPBOX_PLAYGROUND_ID:~/.ssh/config

# we'll need both of these configuration file directories later
labctl cp -r ./configs $JUMPBOX_PLAYGROUND_ID:~/configs

CONTROLLER_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | .[0].name == "controller-1") | .id')

# we also need to get the tailnet IP addresses for each of the controllers, since those need to be passed into each of the etcd
# config files. etcd can only resolve IP addresses for some of the flags, so we need these available.
CONTROLLER_1_IP=$(labctl ssh $CONTROLLER_PLAYGROUND_ID --machine controller-1 "tailscale ip -4" | tr -d '\n\r')
CONTROLLER_2_IP=$(labctl ssh $CONTROLLER_PLAYGROUND_ID --machine controller-2 "tailscale ip -4" | tr -d '\n\r')
CONTROLLER_3_IP=$(labctl ssh $CONTROLLER_PLAYGROUND_ID --machine controller-3 "tailscale ip -4" | tr -d '\n\r')

sed -i "s|CONTROLLER_1_IP|${CONTROLLER_1_IP}|g" ./units/etcd.service
sed -i "s|CONTROLLER_2_IP|${CONTROLLER_2_IP}|g" ./units/etcd.service
sed -i "s|CONTROLLER_3_IP|${CONTROLLER_3_IP}|g" ./units/etcd.service

labctl cp -r ./units $JUMPBOX_PLAYGROUND_ID:~/units

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
