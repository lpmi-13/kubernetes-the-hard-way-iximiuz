openssl genrsa -out ca.key 4096

openssl req -x509 -new -sha512 -noenc \
  -key ca.key -days 3653 \
  -config ca.conf \
  -out ca.crt

certs=(
  "admin" "worker-1" "worker-2"
  "worker-3" "worker-4" "worker-5"
  "worker-6" "worker-7" "worker-8"
  "worker-9" "kube-proxy" "kube-scheduler"
  # we might need to do separate controller certs later
  "kube-controller-manager"
  "kube-api-server" "service-accounts"
)

for i in ${certs[*]}; do
  openssl genrsa -out "${i}.key" 4096

  openssl req -new -key "${i}.key" -sha256 \
    -config "ca.conf" -section ${i} \
    -out "${i}.csr"

  openssl x509 -req -days 3653 -in "${i}.csr" \
    -copy_extensions copyall \
    -sha256 -CA "ca.crt" \
    -CAkey "ca.key" \
    -CAcreateserial \
    -out "${i}.crt"
done

for host in worker-{1..9}; do
  ssh -i ~/.ssh/kubernetes.ed25519 root@${host} "mkdir -p /var/lib/kubelet/"

  scp -i ~/.ssh/kubernetes.ed25519 ca.crt root@${host}:/var/lib/kubelet/

  scp -i ~/.ssh/kubernetes.ed25519 ${host}.crt \
    root@${host}:/var/lib/kubelet/kubelet.crt

  scp -i ~/.ssh/kubernetes.ed25519 ${host}.key \
    root@${host}:/var/lib/kubelet/kubelet.key
done


for host in controller-{1..3}; do
  scp -i ~/.ssh/kubernetes.ed25519 \
    ca.key ca.crt \
    kube-api-server.key kube-api-server.crt \
    service-accounts.key service-accounts.crt \
    root@${host}:~/
done
