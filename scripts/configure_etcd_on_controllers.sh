mv etcd etcdctl /usr/local/bin/

mkdir -p /etc/etcd /var/lib/etcd
chmod 700 /var/lib/etcd
cp ca.crt kube-api-server.key kube-api-server.crt \
  /etc/etcd/

sudo sed -i "s/NODE_NAME/$(hostname -s)/g" etcd.service
sudo sed -i "s/NODE_IP/$(tailscale ip -4)/g" etcd.service

mv etcd.service /etc/systemd/system/

systemctl daemon-reload
systemctl enable etcd
systemctl start etcd

etcdctl member list
