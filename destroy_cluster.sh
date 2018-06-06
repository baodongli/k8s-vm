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
    rm -rf $rootdir/$vm_name
    timeout 60 sh -c "while virsh list --all | grep $vm_name > /dev/null; do
        sleep 1
    done"
done < $hostfile
