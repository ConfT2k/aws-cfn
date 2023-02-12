#!/bin/bash
#
#   AWS EC2 인스턴스용 StrongSwan(IPSec) + Quagga (BGP) 설정 스크립트
#   - 2023/02/23
#
#   사용법
#    1. public subnet에 EC2를 배포하고 나서 EIP를 할당합니다.
#    2. VGW/TGW의 S2S VPN 설정이 EC2에 할당된 EIP 주소를 CGW로 등록하고 S2S VPN 터널을 생성합니다.
#      주) VGW/TGW에서 VPN 터널 설정시 사용자 PSK와 Inner IP 주소는 아래의 파라메터를 사용하여 고정 또는 변경 필요.
#    3. 생성된 터널 정보에서 2개 터널의 Outside IP를 확인한뒤 스크립트를 실행합니다.
#

# CGW(EC2 Instance) Eth0
pCgwEth0Ip=$(hostname -i)
pCgwEip=$(curl -s ifconfig.me)
pCgwCidr="`echo $pCgwEth0Ip | cut -d "." -f 1-3`.0/24"

# IPSec Tunnel #1 Info
pTu1Psk=PqAwSeSrWtOyRyD
pTu1CgwOutsideIp=$pCgwEip
pTu1CgwInsideIp=169.254.100.2
pTu1VgwInsideIp=169.254.100.1

# IPSec Tunnel #2 Info
pTu2Psk=PqAwSeSrWtOyRyD
pTu2CgwOutsideIp=$pCgwEip
pTu2CgwInsideIp=169.254.200.2
pTu2VgwInsideIp=169.254.200.1

echo    "=========================================================="
echo    "              IPSEC/BGP 설정을 시작합니다"
echo    "----------------------------------------------------------"
echo    "  1. IPSec Info - VGW(TGW)의 Tunnel 정보를 입력하세요"
read -p "    - Tunnel #1 Outside IP Addr : " pTu1VgwOutsideIp
read -p "    - Tunnel #2 Outside IP Addr : " pTu2VgwOutsideIp
echo    "    - Tunnel #1 Inside IP Addr : "  ${pTu1VgwInsideIp}
echo    "    - Tunnel #2 Inside IP Addr : "  ${pTu2VgwInsideIp}
echo    "    - Tunnel #1 Pre-Shared Key  : " ${pTu1Psk}
echo    "    - Tunnel #2 Pre-Shared Key  : " ${pTu2Psk}
echo    "----------------------------------------------------------"
echo    "  2. BGP Info -  BGP 설정 정보를 입력하세요"
read -p "    - VGW ASN Number (64512-65534) : " pVgwAsn
read -p "    - CGW ASN Number (64512-65534) : " pCgwAsn
echo    "=========================================================="
echo    ""
read -p "  [!] 위에 입력한 정보가 정확한 가요? 맞으면 계속 (y/N)? " answer
echo

if [ "${answer,,}" != "y" ]
then
    exit 100
fi

sudo yum update -y
sudo amazon-linux-extras install -y epel
sudo yum install strongswan -y
sudo yum install quagga-0.99.22.4 -y
sudo systemctl enable --now strongswan

cat <<EOF > /etc/strongswan/ipsec.conf
#
# /etc/strongswan/ipsec.conf
#
conn %default
        # Authentication Method : Pre-Shared Key
        leftauth=psk
        rightauth=psk
        # Encryption Algorithm : aes-128-cbc
        # Authentication Algorithm : sha1
        # Perfect Forward Secrecy : Diffie-Hellman Group 2
        ike=aes128-sha1-modp1024!
        # Lifetime : 28800 seconds
        ikelifetime=28800s
        # Phase 1 Negotiation Mode : main
        aggressive=no
        # Protocol : esp
        # Encryption Algorithm : aes-128-cbc
        # Authentication Algorithm : hmac-sha1-96
        # Perfect Forward Secrecy : Diffie-Hellman Group 2
        esp=aes128-sha1-modp1024!
        # Lifetime : 3600 seconds
        lifetime=3600s
        # Mode : tunnel
        type=tunnel
        # DPD Interval : 10
        dpddelay=10s
        # DPD Retries : 3
        dpdtimeout=30s
        # Tuning Parameters for AWS Virtual Private Gateway:
        keyexchange=ikev1
        rekey=yes
        reauth=no
        dpdaction=restart
        closeaction=restart
        leftsubnet=0.0.0.0/0,::/0
        rightsubnet=0.0.0.0/0,::/0
        leftupdown=/etc/strongswan/ipsec-vti.sh
        installpolicy=yes
        compress=no
        mobike=no
conn TU1
        # Customer Gateway
        left=${pCgwEth0Ip}
        leftid=${pTu1CgwOutsideIp}
        # Virtual Private Gateway
        right=${pTu1VgwOutsideIp}
        rightid=${pTu1VgwOutsideIp}
        auto=start
        mark=100
conn TU2
        # Customer Gateway
        left=${pCgwEth0Ip}
        leftid=${pTu2CgwOutsideIp}
        # Virtual Private Gateway
        right=${pTu2VgwOutsideIp}
        rightid=${pTu2VgwOutsideIp}
        auto=start
        mark=200
EOF

cat <<EOF > /etc/strongswan/ipsec.secrets
#
# /etc/strongswan/ipsec.secrets
#
${pTu1CgwOutsideIp} ${pTu1VgwOutsideIp} : PSK ${pTu1Psk}
${pTu2CgwOutsideIp} ${pTu2VgwOutsideIp} : PSK ${pTu2Psk}
EOF


cat <<EOF > /etc/strongswan/ipsec-vti.sh
#!/bin/bash

#
# /etc/strongswan/ipsec-vti.sh
#

IP=\$(which ip)
IPTABLES=\$(which iptables)

PLUTO_MARK_OUT_ARR=(\${PLUTO_MARK_OUT//// })
PLUTO_MARK_IN_ARR=(\${PLUTO_MARK_IN//// })

case "\$PLUTO_CONNECTION" in
        TU1)
        VTI_INTERFACE=vti1
        VTI_LOCALADDR=${pTu1CgwInsideIp}/30
        VTI_REMOTEADDR=${pTu1VgwInsideIp}/30
        ;;
        TU2)
        VTI_INTERFACE=vti2
        VTI_LOCALADDR=${pTu2CgwInsideIp}/30
        VTI_REMOTEADDR=${pTu2VgwInsideIp}/30
        ;;
esac

case "\${PLUTO_VERB}" in
        up-client)
        #\$IP tunnel add \${VTI_INTERFACE} mode vti local \${PLUTO_ME} remote \${PLUTO_PEER} okey \${PLUTO_MARK_OUT_ARR[0]} ikey \${PLUTO_MARK_IN_ARR[0]}
        \$IP link add \${VTI_INTERFACE} type vti local \${PLUTO_ME} remote \${PLUTO_PEER} okey \${PLUTO_MARK_OUT_ARR[0]} ikey \${PLUTO_MARK_IN_ARR[0]}
        sysctl -w net.ipv4.conf.\${VTI_INTERFACE}.disable_policy=1
        sysctl -w net.ipv4.conf.\${VTI_INTERFACE}.rp_filter=2 || sysctl -w net.ipv4.conf.\${VTI_INTERFACE}.rp_filter=0
        \$IP addr add \${VTI_LOCALADDR} remote \${VTI_REMOTEADDR} dev \${VTI_INTERFACE}
        \$IP link set \${VTI_INTERFACE} up mtu 1436
        \$IPTABLES -t mangle -I FORWARD -o \${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        \$IPTABLES -t mangle -I INPUT -p esp -s \${PLUTO_PEER} -d \${PLUTO_ME} -j MARK --set-xmark \${PLUTO_MARK_IN}
        \$IP route flush table 220
        #/etc/init.d/bgpd reload || /etc/init.d/quagga force-reload bgpd
        ;;
        down-client)
        #\$IP tunnel del \${VTI_INTERFACE}
        \$IP link del \${VTI_INTERFACE}
        \$IPTABLES -t mangle -D FORWARD -o \${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        \$IPTABLES -t mangle -D INPUT -p esp -s \${PLUTO_PEER} -d \${PLUTO_ME} -j MARK --set-xmark \${PLUTO_MARK_IN}
        ;;
esac

# Enable IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.eth0.disable_xfrm=1
sysctl -w net.ipv4.conf.eth0.disable_policy=1
# Disable IPv4 ICMP Redirect
sysctl -w net.ipv4.conf.eth0.accept_redirects=0
sysctl -w net.ipv4.conf.eth0.send_redirects=0

EOF


cat <<EOF > /etc/quagga/bgpd.conf
#
# /etc/quagga/bgpd.conf
#
router bgp ${pCgwAsn}
bgp router-id ${pTu1CgwInsideIp}
neighbor ${pTu1VgwInsideIp} remote-as ${pVgwAsn}
neighbor ${pTu2VgwInsideIp} remote-as ${pVgwAsn}
network ${pCgwCidr}
EOF


sudo systemctl start zebra
sudo systemctl enable zebra
sudo systemctl start bgpd
sudo systemctl enable bgpd
sudo chmod -R 777 /etc/quagga/



sudo strongswan restart
