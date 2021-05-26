#!/bin/bash

set -eux

clang -O2 -Wall -target bpf -c bpf_xdp_veth_host.c -o bpf_xdp_veth_host.o
clang -O2 -Wall -target bpf -c test_tc_tunnel.c -o test_tc_tunnel.o

kind create cluster --config kind-config.yaml
kubectl apply -f cilium-lb.yaml

IFIDX=$(docker exec -i kind-control-plane \
    /bin/sh -c 'echo $(( $(ip -o l show eth0 | awk "{print $1}" | cut -d: -f1) ))')
LB_VETH_HOST=$(ip -o l | grep "if$IFIDX" | awk '{print $2}' | cut -d@ -f1)
ip l set dev $LB_VETH_HOST  xdp obj bpf_xdp_veth_host.o
ethtool -K $LB_VETH_HOST rx off tx off
LB_IP=$(docker exec -ti kind-control-plane ip -o -4 a s eth0 | awk '{print $4}' | cut -d/ -f1)

docker exec -ti kind-worker2 /bin/sh -c 'apt-get update && apt-get install -y nginx && systemctl start nginx'
WORKER2_IP=$(docker exec -ti kind-worker2 ip -o -4 a s eth0 | awk '{print $4}' | cut -d/ -f1)
nsenter -t $(docker inspect kind-worker2 -f '{{ .State.Pid }}') -n /bin/sh -c \
    'tc qdisc add dev eth0 clsact && tc filter add dev eth0 ingress bpf direct-action object-file ./test_tc_tunnel.o section decap && ip a a dev eth0 2.2.2.2/32'

CILIUM_POD_NAME=$(kubectl -n kube-system get pod -l k8s-app=cilium -o=jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system wait --for=condition=Ready pod "$CILIUM_POD_NAME"
kubectl -n kube-system exec -ti $CILIUM_POD_NAME -- \
    cilium service update --id 1 --frontend "2.2.2.2:80" --backends "${WORKER2_IP}:80" --k8s-node-port

ip r a 2.2.2.2/32 via "$LB_IP"

for i in $(seq 1 10); do
    curl "2.2.2.2:80"
done
