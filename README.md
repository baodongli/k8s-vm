# [WIP] Deploy a K8s cluster using VMs on a Baremetal Machine

The scripts can be used to

- create a kubernetes cluster with a master and one or more minion nodes
- deploy istio and the sample bookinfo service
- destroy a kubernetes cluster

## PREREQUISITE of The Baremetal Machine

- ubuntu 16.04
- apt-get install -y vncviewer vim-gnome qemu-system libvirt-bin libvirt-dev
  qemu-kvm xterm cloud-guest-utils libguestfs-tools
- an interface dedicated for the VM's dataplane

## CREATE A KUBERNETES CLUSTER

- sudo bash
- cd to the directory where the scritps reside
- ./create_cluster.sh ```<nodes-desc-file> <dataplane interface> [<istio>]```
- ./create_v6_cluster.sh ```<nodes-desc-file> <dataplane interface> [<istio>]```

For v6 cluster, see v6-host-cluster.txt for an example of nodes-desc-file
For v4 cluster, see host-cluster.txt for an example of nodes-desc-file

## DESTROY A KUBERNETES CLUSTER

  ./destroy_cluster.sh <nodes-desc-file>

## CREATE a KUBERNETES FEDERATION

  ./create-k8s-fed.sh <fed-def.txt>

The fed-def.txt file defines the command lines to start k8s clusters. Once example is shown in below:

```
host-cluster.txt enp9s0 
kube-cluster2.txt enp9s0 
```

