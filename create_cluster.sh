set -x 
date
rootdir=$PWD
hostfile=$1
intf=$2
deploy_istio=$3
cni=$4

if [[ -z $(sudo brctl show | grep kube-bridge) ]]; then
    sudo brctl addbr kube-bridge
    sudo ip link set kube-bridge up
    sudo ip set link $intf up
    sudo brctl addif kube-bridge $intf
fi


function generate_mac ()  {
  hexchars="0123456789abcdef"
  echo "fa:16:3e$(
    for i in {1..6}; do 
      echo -n ${hexchars:$(( $RANDOM % 16 )):1}
    done | sed -e 's/\(..\)/:\1/g'
  )"
}


function customize_image {
    vmdir=$1
    image=$vmdir/$2
    
    mntdir=/mnt/$CLUSTER_NAME
    mkdir -p $mntdir
    guestmount -a $image -m /dev/sda1 $mntdir
    cp $vmdir/hostname $mntdir/etc/hostname
    cp $vmdir/interfaces $mntdir/etc/network/interfaces
    cp $rootdir/hosts.$CLUSTER_NAME $mntdir/etc/hosts
    cp /root/.ssh/id_rsa.pub $mntdir/home/devuser/.ssh/authorized_keys
    guestunmount $mntdir
    rmdir $mntdir
}

function create_vm {
    vm_type=$1
    vm_name=$2
    vm_ipaddr=$3
    vm_gw_ip=$4
    vm_ip_netmask=$5

    vmdir=$rootdir/$vm_name
    sudo rm -rf $vmdir
    mkdir -p $vmdir
    sudo cp $rootdir/cluster.qcow2 $vmdir/$vm_name.qcow2
    echo $vm_name > $vmdir/hostname

    cat > $vmdir/interfaces <<-EOF
        # This file describes the network interfaces available on your system
        # and how to activate them. For more information, see interfaces(5).
        
        # The loopback network interface
        auto lo
        iface lo inet loopback
        
        auto ens3
        iface ens3 inet static
            address $vm_ipaddr
            netmask $vm_ip_netmask
            gateway $vm_gw_ip
            dns-nameservers 173.36.131.10
            dns-search cisco.com
        
        # Source interfaces
        # Please check /etc/network/interfaces.d before changing this file
        # as interfaces may have been defined in /etc/network/interfaces.d
        # See LP: #1262951
        source /etc/network/interfaces.d/*.cfg
EOF
    
    customize_image $vmdir $vm_name.qcow2

    if [[ -f $rootdir/$vm_name.mac ]]; then
        mac_addr=$(cat $rootdir/$vm_name.mac)
    else
        mac_addr=$(generate_mac)
        echo $mac_addr > $rootdir/$vm_name.mac
    fi

    vmxml=$vmdir/$vm_name.xml
    cat > $vmxml <<-EOF
        <domain type='kvm'>
          <name>$vm_name</name>
          <uuid>$(uuidgen)</uuid>
          <memory unit='KiB'>8388608</memory>
          <currentMemory unit='KiB'>8388608</currentMemory>
          <vcpu placement='static'>4</vcpu>
          <cputune>
            <shares>4096</shares>
          </cputune>
          <resource>
            <partition>/machine</partition>
          </resource>
          <os>
            <type arch='x86_64' machine='pc-i440fx-xenial'>hvm</type>
            <boot dev='hd'/>
          </os>
          <features>
            <acpi/>
            <apic/>
          </features>
          <cpu>
            <topology sockets='4' cores='1' threads='1'/>
          </cpu>
          <clock offset='utc'>
            <timer name='pit' tickpolicy='delay'/>
            <timer name='rtc' tickpolicy='catchup'/>
            <timer name='hpet' present='no'/>
          </clock>
          <on_poweroff>destroy</on_poweroff>
          <on_reboot>restart</on_reboot>
          <on_crash>destroy</on_crash>
          <devices>
            <emulator>/usr/bin/kvm-spice</emulator>
            <disk type='file' device='disk'>
              <driver name='qemu' type='qcow2' cache='none'/>
              <source file='$vmdir/$vm_name.qcow2'/>
              <target dev='vda' bus='virtio'/>
              <address type='pci' domain='0x0000' bus='0x00' slot='0x04' function='0x0'/>
            </disk>
            <controller type='usb' index='0'>
              <address type='pci' domain='0x0000' bus='0x00' slot='0x01' function='0x2'/>
            </controller>
            <controller type='pci' index='0' model='pci-root'/>
            <interface type='bridge'>
              <mac address='$mac_addr'/>
              <source bridge='kube-bridge'/>
              <target dev='${vm_name}'/>
              <model type='virtio'/>
              <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
            </interface>
            <serial type='pty'>
              <target port='1'/>
            </serial>
            <console type='pty'>
              <target type='serial' port='1'/>
            </console>
            <input type='mouse' bus='ps2'/>
            <input type='keyboard' bus='ps2'/>
            <graphics type='vnc' port='-1' autoport='yes' listen='0.0.0.0' keymap='en-us'>
              <listen type='address' address='0.0.0.0'/>
            </graphics>
            <video>
              <model type='cirrus' vram='16384' heads='1'/>
              <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0'/>
            </video>
            <memballoon model='virtio'>
              <stats period='10'/>
              <address type='pci' domain='0x0000' bus='0x00' slot='0x05' function='0x0'/>
            </memballoon>
          </devices>
          <seclabel type='dynamic' model='apparmor' relabel='yes'/>
        </domain>
EOF
   sudo virsh define $vmxml
   sudo virsh start $vm_name
}

while read -r line; do
    if [[ "$line" =~ ^[[:space:]]*#.* ]]; then
        continue
    fi

    params=($line)
    
    if [[ ${params[0]} == 'cluster' ]]; then
        CLUSTER_NAME=${params[1]}
        CLUSTER_CTXT=${params[2]}
        CLUSTER_USER=${params[3]}
        CLUSTER_REGION=${params[4]}
        CLUSTER_ZONE=${params[5]}
        CLUSTER_POD_CIDR=${params[6]}
        break
    fi
done < $hostfile

rm -f $rootdir/hosts.$CLUSTER_NAME
echo 127.0.0.1 localhost > $rootdir/hosts.$CLUSTER_NAME
while read -r vm; do
    if [[ "$vm" =~ ^[[:space:]]*#.* ]]; then
        continue
    fi

    vm_params=($vm)
    vm_name=${vm_params[1]}
    vm_ipaddr=${vm_params[2]}
    
    if [[ ${vm_params[0]} == 'cluster' ]]; then
        continue
    fi
    echo $vm_ipaddr $vm_name >> $rootdir/hosts.$CLUSTER_NAME
done < $hostfile


while read -r vm; do
    if [[ "$vm" =~ ^[[:space:]]*#.* ]]; then
        continue
    fi
    vm_params=($vm)
    vm_type=${vm_params[0]}
    vm_name=${vm_params[1]}
    vm_ipaddr=${vm_params[2]}
    if [[ $vm_type == 'cluster' ]]; then
        continue
    fi
    if [[ $vm_type == 'master' ]]; then
        master_vm_name=$vm_name
        master_vm_ipaddr=$vm_ipaddr
    fi

    if [[ -n $vm_name && -n vm_ipaddr ]]; then
        create_vm $vm
    else
        echo "Can't create vm without name or IP"
    fi
done < $hostfile

# https://github.com/kubernetes/kubernetes/pull/52470
# before it's available, we need to modify the admin.conf
function modify_cluster_conf {
    ca_data=($(grep certificate-authority-data: $rootdir/${CLUSTER_NAME}.conf.orig))
    ca_data=${ca_data[1]}

    client_ca=($(grep client-certificate-data: $rootdir/${CLUSTER_NAME}.conf.orig))
    client_ca=${client_ca[1]}

    client_key_data=($(grep client-key-data: $rootdir/${CLUSTER_NAME}.conf.orig))
    client_key_data=${client_key_data[1]}
  
    server=($(grep server: $rootdir/${CLUSTER_NAME}.conf.orig))
    server=${server[1]}

    cat > $rootdir/${CLUSTER_NAME}.conf <<-EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: $ca_data
    server: $server
  name: $CLUSTER_NAME
contexts:
- context:
    cluster: $CLUSTER_NAME
    user: $CLUSTER_USER
  name: $CLUSTER_CTXT
current-context: $CLUSTER_CTXT
kind: Config
preferences: {}
users:
- name: $CLUSTER_USER
  user:
    client-certificate-data: $client_ca
    client-key-data: $client_key_data
EOF
}

function kubeadm_init_master {
    master_ip=$1
    master_name=$2
    
    echo "Waiting for $master_name to come up"
    timeout 120 sh -c "while ! ping -W 1 -c 1 $master_ip; do
        sleep 1
    done"

    while ! ssh -o "StrictHostKeyChecking no" devuser@$master_ip ls; do
        sleep 3
    done

    ssh_cmd="ssh -n devuser@$master_ip"
    vmdir=$rootdir/$master_name
    
    cat > $vmdir/kubeadm.conf <<-EOF
        networking:
          podSubnet: $CLUSTER_POD_CIDR
        nodeName: $master_name
EOF

    $ssh_cmd sudo sysctl -w net.ipv6.conf.ens3.disable_ipv6=1

    while ! $ssh_cmd sudo apt-get update; do
        sleep 10
    done

    while ! $ssh_cmd sudo apt-get install -y apt-transport-https; do
        sleep 10
    done

    $ssh_cmd "curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -"

    while ! $ssh_cmd sudo apt-get update; do
        sleep 10
    done

    while ! $ssh_cmd sudo apt-get install -y kubelet kubeadm kubectl kubernetes-cni; do
        sleep 10
    done

    scp $vmdir/kubeadm.conf devuser@$master_ip:/home/devuser/kubeadm.conf
    $ssh_cmd sudo rm -rf /var/lib/kubelet
    kubeadm_join_cmd=$($ssh_cmd sudo kubeadm init --config /home/devuser/kubeadm.conf | grep 'kubeadm join')
    $ssh_cmd sudo systemctl enable kubelet.service

    $ssh_cmd mkdir -p '$HOME'/.kube
    $ssh_cmd sudo chmod a+r /etc/kubernetes/admin.conf
    scp devuser@$master_ip:/etc/kubernetes/admin.conf $rootdir/${CLUSTER_NAME}.conf.orig
    modify_cluster_conf
    scp $rootdir/${CLUSTER_NAME}.conf devuser@$master_ip:/home/devuser/.kube/config
    $ssh_cmd sudo cp /home/devuser/.kube/config /etc/kubernetes/admin.conf
    $ssh_cmd sudo chown $(id -u):$(id -g) '$HOME'/.kube/config

    if [[ $cni == 'flannel' ]]; then
        $ssh_cmd sudo kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
    elif [[ $cni == 'calico' ]]; then
        $ssh_cmd sudo kubectl apply -f https://docs.projectcalico.org/v3.0/getting-started/kubernetes/installation/hosted/kubeadm/1.7/calico.yaml
    fi
    #$ssh_cmd sudo kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel-rbac.yml
}

function label_nodes {
    master_ip=$1
    master_name=$2

    ssh_cmd="ssh -n devuser@$master_ip"
    $ssh_cmd sudo kubectl label --all nodes failure-domain.beta.kubernetes.io/region=$CLUSTER_REGION
    $ssh_cmd sudo kubectl label --all nodes failure-domain.beta.kubernetes.io/zone=$CLUSTER_ZONE
}

function kubeadm_join_minion {
    minion_name=$1
    minion_ip=$2

    echo "Waiting for $minion_name to come up"
    timeout 120 sh -c "while ! ping -W 1 -c 1 $minion_ip; do
        sleep 1
    done"
    
    while ! ssh -n -o "StrictHostKeyChecking no" devuser@$minion_ip ls; do
        sleep 3
    done 

    ssh_cmd="ssh -n devuser@$minion_ip"
    $ssh_cmd sudo sysctl -w net.ipv6.conf.ens3.disable_ipv6=1
    while ! $ssh_cmd sudo apt-get update; do
        sleep 10
    done

    while ! $ssh_cmd sudo apt-get install -y apt-transport-https; do
        sleep 10
    done

    $ssh_cmd "curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -"

    while ! $ssh_cmd sudo apt-get update; do
        sleep 10
    done

 
    while ! $ssh_cmd sudo apt-get install -y kubelet kubeadm kubectl kubernetes-cni; do
        sleep 10
    done

    $ssh_cmd sudo rm -rf /var/lib/kubelet
    $ssh_cmd sudo $kubeadm_join_cmd
    $ssh_cmd sudo systemctl enable kubelet.service
    $ssh_cmd mkdir -p '$HOME'/.kube
    scp $rootdir/${CLUSTER_NAME}.conf devuser@$minion_ip:/home/devuser/.kube/config
    $ssh_cmd sudo chown $(id -u):$(id -g) '$HOME'/.kube/config
    scp $rootdir/map_ns.sh devuser@$minion_ip:/home/devuser/
    $ssh_cmd sudo chown $(id -u):$(id -g) '$HOME'/map_ns.sh
    scp $rootdir/unmap_ns.sh devuser@$minion_ip:/home/devuser/
    $ssh_cmd sudo chown $(id -u):$(id -g) '$HOME'/unmap_ns.sh
    $ssh_cmd sudo chmod u+x '$HOME'/map_ns.sh
    $ssh_cmd sudo chmod u+x '$HOME'/unmap_ns.sh
    # label the node
}


function deploy_helm {
    master_ip=$1
    master_name=$2

    ssh_cmd="ssh -n devuser@$master_ip"

    echo "Waiting for all the nodes to be ready"
    timeout 360 sh -c "while $ssh_cmd 'sudo kubectl get nodes | grep NotReady > /dev/null'; do
        sleep 10
    done"

    $ssh_cmd 'sudo curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > get_helm.sh'
    $ssh_cmd sudo chmod 700 get_helm.sh
    $ssh_cmd sudo ./get_helm.sh
    scp $rootdir/helm_svc_acct.yaml devuser@$master_ip:/home/devuser
    $ssh_cmd sudo kubectl create -f helm_svc_acct.yaml
    $ssh_cmd sudo helm init --service-account helm
    
    echo "Waiting for tiller pod to go active"
    timeout 360 sh -c "while ! $ssh_cmd 'sudo kubectl get pods -o wide -n kube-system | grep tiller | grep 1/1 | grep Running > /dev/null'; do
        sleep 5
    done"

    $ssh_cmd sudo kubectl get pods -o wide -n kube-system 
    $ssh_cmd sudo helm repo add incubator http://storage.googleapis.com/kubernetes-charts-incubator
}

function deploy_istio {
    master_ip=$1
    master_name=$2

    ssh_cmd="ssh -n devuser@$master_ip"

    $ssh_cmd sudo helm install --name first-istio incubator/istio --set rbac.install=true
    echo "Waiting for istio to go active"
    timeout 360 sh -c "while $ssh_cmd 'sudo kubectl get pods -o wide | grep -v RESTARTS | grep -v Running > /dev/null'; do
        sleep 10
    done"
    $ssh_cmd sudo kubectl get pods -o wide 

    # get the source and istioctl
    $ssh_cmd 'cd /opt; sudo curl -L https://git.io/getIstio | sudo sh -'
    $ssh_cmd 'cd /opt; dir=$(ls | grep istio-); cd $dir; echo "PATH=$PATH:$PWD/bin;" >> ~/.profile'
}

function deploy_bookinfo {
    master_ip=$1
    master_name=$2
    
    ssh_cmd="ssh -n devuser@$master_ip"
    scp $rootdir/deploy_bookinfo.sh devuser@$master_ip:/home/devuser
    $ssh_cmd chmod u+x ./deploy_bookinfo.sh
    $ssh_cmd sudo ./deploy_bookinfo.sh $master_ip
    echo "Now you can ssh devuser@$master_ip, and launch firefox with http://localhost:3000/dashboard/db/istio-dashboard"
}

kubeadm_init_master $master_vm_ipaddr $master_vm_name

while read -r vm; do
    if [[ "$vm" =~ ^[[:space:]]*#.* ]]; then
        continue
    fi
    vm_params=($vm)
    vm_type=${vm_params[0]}
    vm_name=${vm_params[1]}
    vm_ipaddr=${vm_params[2]}

    if [[ $vm_type == 'cluster' ]]; then
        continue
    fi
    if [[ $vm_type == 'minion' ]]; then
        kubeadm_join_minion $vm_name $vm_ipaddr
    fi
done < $hostfile

deploy_helm $master_vm_ipaddr $master_vm_name
label_nodes $master_vm_ipaddr $master_vm_name


if [[ $deploy_istio == 'istio' ]]; then
    deploy_istio $master_vm_ipaddr $master_vm_name
    deploy_bookinfo $master_vm_ipaddr $master_vm_name
fi
date
