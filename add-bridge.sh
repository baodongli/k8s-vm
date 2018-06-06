set -x
ipv4_addr=$(ip a show ens3 | grep "inet " | grep global | awk '{print $2}')
ipv6_addr=$(ip a show ens3 | grep "inet6 " | grep global | awk '{print $2}')
echo $ipv4_addr > ./hostip
macaddr=$(ip a show ens3 | grep "link\/ether " | awk '{print $2}')
sudo brctl addbr ds-ingress-br
sudo ip link set ds-ingress-br address $macaddr
sudo ip link add dev ingress-c type veth peer name ingress-h
sudo brctl addif ds-ingress-br ens3
sudo ip link set ds-ingress-br up
sudo ip addr del $ipv4_addr dev ens3
sudo ip addr del $ipv6_addr dev ens3
sudo brctl addif ds-ingress-br ingress-h
sudo ip link set ingress-c up
sudo ip link set ingress-h up
sudo ip addr add $ipv4_addr dev ingress-c
sudo ip route add 0.0.0.0/0 via 10.86.7.65 dev ingress-c

# accept_ra must be 2 to retain ra when forwarding is enabled
sudo sysctl -w net.ipv6.conf.ds-ingress-br.accept_ra=2
sudo sysctl -w net.ipv6.conf.all.forwarding=1
sudo sysctl -w net.ipv6.conf.all.accept_ra=2
