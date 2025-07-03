for i in {1..4}; do
  labctl playground start mini-lan-ubuntu -f -<<EOF
    kind: playground
    playground:
      machines:
      - name: node-01
      - name: node-02
      - name: node-03
EOF
done
