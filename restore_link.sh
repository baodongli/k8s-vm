#!/bin/bash

set -x 
sudo brctl addbr kube-bridge
sudo ip link set kube-bridge up
sudo ip link set enp8s0 up
sudo brctl addif kube-bridge enp9s0


