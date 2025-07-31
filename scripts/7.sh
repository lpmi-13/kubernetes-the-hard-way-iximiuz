JUMPBOX_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | length == 1 and .[0].name == "jumpbox") | .id')

labctl cp ./scripts/copy_etcd_config_to_controllers.sh $JUMPBOX_PLAYGROUND_ID:~/copy_etcd_config_to_controllers.sh

labctl ssh $JUMPBOX_PLAYGROUND_ID "bash ~/copy_etcd_config_to_controllers.sh"

CONTROLLER_PLAYGROUND_ID=$(labctl playground list -o json | jq -r '.[] | select(.machines | .[0].name == "controller-1") | .id')

# we also need to get the tailnet IP addresses for each of the controllers, since those need to be passed into each of the etcd
# config files
CONTROLLER_1_IP=$(labctl ssh $CONTROLLER_PLAYGROUND_ID --machine controller-1 "tailscale ip -4")
CONTROLLER_2_IP=$(labctl ssh $CONTROLLER_PLAYGROUND_ID --machine controller-2 "tailscale ip -4")
CONTROLLER_3_IP=$(labctl ssh $CONTROLLER_PLAYGROUND_ID --machine controller-3 "tailscale ip -4")

for machine_name in $(labctl playground machines $CONTROLLER_PLAYGROUND_ID | sed '1d'); do
  labctl cp ./scripts/configure_etcd_on_controllers.sh $CONTROLLER_PLAYGROUND_ID:~/configure_etcd_on_controllers.sh --machine $machine_name
  labctl ssh $CONTROLLER_PLAYGROUND_ID --machine $machine_name "bash ~/configure_etcd_on_controllers.sh"
done
