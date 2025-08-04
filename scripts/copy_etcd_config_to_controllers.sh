# we also need to get the tailnet IP addresses for each of the controllers, since those need to be passed into each of the etcd
# config files. etcd can only resolve IP addresses for some of the flags, so we need these available.
CONTROLLER_1_IP=$(ssh -i ~/.ssh/kubernetes.ed25519 controller-1 "tailscale ip -4" | tr -d '\n\r')
CONTROLLER_2_IP=$(ssh -i ~/.ssh/kubernetes.ed25519 controller-2 "tailscale ip -4" | tr -d '\n\r')
CONTROLLER_3_IP=$(ssh -i ~/.ssh/kubernetes.ed24419 controller-3 "tailscale ip -4" | tr -d '\n\r')

# now we swap those into the unit file for the placeholder values
sed -i "s|CONTROLLER_1_IP|${CONTROLLER_1_IP}|g" ./units/etcd.service
sed -i "s|CONTROLLER_2_IP|${CONTROLLER_2_IP}|g" ./units/etcd.service
sed -i "s|CONTROLLER_3_IP|${CONTROLLER_3_IP}|g" ./units/etcd.service

for host in controller-{1..3}; do
  scp -i ~/.ssh/kubernetes.ed25519 \
    downloads/controller/etcd \
    downloads/client/etcdctl \
    units/etcd.service \
    root@${host}:~/
done
