rootdir=$PWD
hostfile=$1

while read -r vm; do
    if [[ "$vm" =~ ^[[:space:]]*#.* ]]; then
        continue
    fi
    vm_params=($vm)
    vm_name=${vm_params[1]}

    if [[ ${vm_params[0]} == 'cluster' ]]; then
        continue
    fi

    virsh shutdown $vm_name
    virsh undefine $vm_name
    if [[ $? == 0 && -n $vm_name ]]; then
        rm -rf $rootdir/$vm_name
    fi
    timeout 60 sh -c "while virsh list --all | grep $vm_name > /dev/null; do
        sleep 1
    done"
done < $hostfile
