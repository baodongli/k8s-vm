set -x 
date
rootdir=$PWD
hostfile=$1
intf=$2
deploy_istio=$3

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
    sudo cp $rootdir/vm.qcow2 $vmdir/$vm_name.qcow2
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
