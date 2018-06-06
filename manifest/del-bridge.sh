set -x

ipv4_addr=`cat ./hostip`
sudo brctl delif ds-ingress-br ens3
sudo brctl delif ds-ingress-br ingress-h
sudo ip link del ingress-h
sudo ip link set ds-ingress-br down
sudo brctl delbr ds-ingress-br
sudo ip addr add $ipv4_addr dev ens3
sudo ip route add 0.0.0.0/0 via 10.86.7.65 dev ens3
