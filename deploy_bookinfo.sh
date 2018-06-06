#!/bin/bash

set -x
master_ip=$1
cd /opt
dir=$(ls | grep istio-)
cd $dir
export PATH=$PATH:$PWD/bin
kubectl apply -f <(istioctl kube-inject -f samples/apps/bookinfo/bookinfo.yaml)

timeout 360 sh -c "while kubectl get pods -o wide | grep -v RESTARTS | grep -v Running > /dev/null; do
        sleep 10
done"

grafana_pod=$(kubectl get pods -o wide | grep grafana | awk '{print $1}')
kubectl port-forward $grafana_pod 3000:3000 < /dev/null >& /dev/null &
sgraph_pod=$(kubectl get pods -o wide | grep servicegraph | awk '{print $1}')
kubectl port-forward $sgraph_pod 8088:8088  < /dev/null >& /dev/null &
istio_ingress_port=$(kubectl get svc | grep istio-ingress | awk '{print $4}')
istio_ingress_port=${istio_ingress_port/:/ }
istio_ingress_port=(${istio_ingress_port/\// })
curl http://$master_ip:${istio_ingress_port[1]}/productpage > /dev/null
