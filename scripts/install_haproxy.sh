sudo apt update && sudo apt install -y haproxy

sudo systemctl enable haproxy

cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg > /dev/null
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode http
    option httplog
    option dontlognull
    timeout connect 5000
    timeout client 50000
    timeout server 50000
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 403 /etc/haproxy/errors/403.http
    errorfile 408 /etc/haproxy/errors/408.http
    errorfile 500 /etc/haproxy/errors/500.http
    errorfile 502 /etc/haproxy/errors/502.http
    errorfile 503 /etc/haproxy/errors/503.http
    errorfile 504 /etc/haproxy/errors/504.http

frontend kubernetes_api
    bind *:6443
    default_backend k8s_controllers

backend k8s_controllers
    balance roundrobin
    server controller-1 controller-1:6443 check
    server controller-2 controller-2:6443 check
    server controller-3 controller-3:6443 check

listen stats
    bind *:9000
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats auth admin:ChangeThisPassword

EOF

sudo systemctl restart haproxy
