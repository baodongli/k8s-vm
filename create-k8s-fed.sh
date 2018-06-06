set -x
rootdir=$PWD
clusters=$1
host_cluster_file=
cluster_names=()

while read -r line; do
    params=($line)

    while read -r vm; do
        vm_params=($vm)
        vm_type=${vm_params[0]}
        vm_name=${vm_params[1]}
        vm_ipaddr=${vm_params[2]}
        if [[ $vm_type == 'cluster' ]]; then
            cluster_name=${vm_name}
            cluster_names+=(${vm_name})
        fi
        if [[ $vm_type == 'master' && -z $host_cluster_file ]]; then
            master_vm_name=$vm_name
            master_vm_ipaddr=$vm_ipaddr
        fi
    done < ${params[0]}

    if [[ -z $host_cluster_file ]]; then
        host_cluster_file=${params[0]}
    fi

    $rootdir/create_cluster.sh $line >& create-k8s.${cluster_name}.log&  
done < $clusters

echo host master ip: $master_vm_ipaddr
echo clusters: ${cluster_names[@]}

function prepare_host_master {
    wait

    ssh_cmd="ssh -n devuser@$master_vm_ipaddr"

    if [[ -d /opt/cto-tools ]]; then
        pushd /opt/cto-tools
        # git pull
        popd
    else
        pushd /opt
        git clone https://cto-github.cisco.com/cloudcomputing/cto-tools
        popd
    fi
    $ssh_cmd sudo mkdir -p /opt/cto-tools
    $ssh_cmd sudo chown -R devuser:devuser /opt/cto-tools
    scp -r /opt/cto-tools/* devuser@$master_vm_ipaddr:/opt/cto-tools
    $ssh_cmd mkdir -p /home/devuser/fed-cfg
    for ccf in ${cluster_names[@]}; do
        scp $rootdir/$ccf.conf devuser@$master_vm_ipaddr:/home/devuser/fed-cfg
        $ssh_cmd sudo chown $(id -u):$(id -g) /home/devuser/fed-cfg/$ccf.conf
    done

    scp $rootdir/deploy-k8s-fed.sh devuser@$master_vm_ipaddr:/home/devuser/
    $ssh_cmd chmod u+x ./deploy-k8s-fed.sh
    $ssh_cmd sudo ./deploy-k8s-fed.sh $master_vm_ipaddr ${cluster_names[@]}
}

prepare_host_master
