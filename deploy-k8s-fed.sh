#!/bin/bash

set -x
master_ip=$1
host_cluster=$2
shift 2
non_host_clusters=$@

function all_pods_running {
    namespace=$1
    timeout 360 sh -c "while kubectl get pods -n $namespace | grep -v RESTARTS | grep -v Running > /dev/null; do
        sleep 10
    done"
}

# deploy etcd-operator and an etcd cluster
pushd /opt
git clone https://github.com/coreos/etcd-operator
kubectl apply -f /opt/cto-tools/kubernetes/manifests/role.yaml
cd /opt/etcd-operator/example
kubectl apply -f deployment.yaml
while ! kubectl get pods -n default | grep etcd-operator | grep Running > /dev/null; do
    sleep 1
done 
kubectl apply -f example-etcd-cluster.yaml
popd

all_pods_running default

# deploy coredns
helm install --name coredns -f /opt/cto-tools/kubernetes/manifests/Values.yaml stable/coredns
all_pods_running default

coredns_svc=$(kubectl get svc | grep coredns-coredns | awk '{print $4}')
coredns_svc=${coredns_svc/:/ }
coredns_svc=(${coredns_svc/\// })
coredns_port=${coredns_svc[1]}

cat > /home/devuser/fed-cfg/coredns-provider.conf <<EOF
[Global]
etcd-endpoints = http://example-etcd-cluster-client.default:2379
zones = example.com.
coredns-endpoints = $master_ip:$coredns_port
EOF

# install kubefed
pushd /opt
mkdir kubefed
cd kubefed
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/kubernetes-client-linux-amd64.tar.gz
tar -xzvf kubernetes-client-linux-amd64.tar.gz
mv /usr/bin/kubectl /usr/bin/kubectl.orig
cp kubernetes/client/bin/* /usr/bin
popd

fedcfg=/home/devuser/fed-cfg/$host_cluster.conf
host_context=$(grep current-context: $fedcfg | awk '{print $2}')
non_host_contexts=()
for cluster in ${non_host_clusters[@]}; do
    fedcfg=${fedcfg}:/home/devuser/fed-cfg/${cluster}.conf
    non_host_contexts+=($(grep current-context: /home/devuser/fed-cfg/${cluster}.conf | awk '{print $2}'))
done
all_contexts=($host_context)
all_contexts+=(${non_host_contexts[@]})

export KUBECONFIG=$fedcfg
kubectl config use-context $host_context

# Init the Federation
kubefed init fellowship \
    --host-cluster-context=$host_context \
    --dns-provider="coredns" \
    --dns-zone-name="example.com." \
    --dns-provider-config="/home/devuser/fed-cfg/coredns-provider.conf" \
    --api-server-service-type="NodePort" \
    --api-server-advertise-address="$master_ip" \
    --etcd-persistent-storage=false

all_pods_running federation-system

kubectl create namespace default --context=fellowship
kubectl config use-context fellowship

# after this point, the current context is fellowship
# join all the clusters to the federation
for context in ${all_contexts[@]}; do
    kubefed join $context --host-cluster-context=$host_context
done

# display the clusters
kubectl get clusters

# deploy a cloud provider on all the clusters
# add coredns server in kube-dns server chain
let net=1
for context in ${all_contexts[@]}; do
    kubectl config use-context $context
    kubectl create sa keepalived -n kube-system
    kubectl create clusterrolebinding keepalived --clusterrole=cluster-admin --serviceaccount=kube-system:keepalived
    kubectl apply -f /opt/cto-tools/kubernetes/federation/keepalived-vip/
    cidr=10.210.${net}.100
    tmpfile=$(mktemp)
    sed -r "/pick a CIDR/ s/([0-9]{1,3}\.){3}[0-9]{1,3}/${cidr}/" /opt/cto-tools/kubernetes/federation/keepalived-cloud-provider/deployment.yaml > $tmpfile
    kubectl apply -f $tmpfile
    rm $tmpfile
    let net++

    tmpfile=$(mktemp)
    kubectl get deployment kube-dns -n kube-system -o yaml > $tmpfile
    sed -i "/image: gcr.io\/google_containers\/k8s-dns-dnsmasq/ i \        - --server=/example.com./${master_ip}#${coredns_port}" $tmpfile
    kubectl apply -f $tmpfile
    rm $tmpfile
done
