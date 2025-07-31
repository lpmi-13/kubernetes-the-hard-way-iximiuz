for host in controller-{1..3}; do
  scp -i ~/.ssh/kubernetes.ed25519 \
    downloads/controller/etcd \
    downloads/client/etcdctl \
    units/etcd.service \
    root@${host}:~/
done
