# StrongSwan + FRR setup

## 1.1 StrongSwan 설치

```
sudo yum update -y
sudo amazon-linux-extras install -y epel
sudo yum install strongswan -y
```

## 1.2 StrongSwan 설정

### a. ipsec.conf 설정

```
pEc2Eth0Ip=172.19.19.10

pTu1Psk=PqAwSeSrWtOyRyD
pTu1CgwOutsideIp=54.180.213.90
pTu1VgwOutsideIp=3.69.86.199
pTu1CgwInsideIp=169.254.100.2
pTu1VgwIntsideIp=169.254.100.1

pTu2Psk=PqAwSeSrWtOyRyD
pTu2CgwOutsideIp=54.180.213.90
pTu2VgwOutsideIp=3.120.101.10
pTu2CgwInsideIp=169.254.200.2
pTu2VgwIntsideIp=169.254.200.1

pCgwAsn=64582
pVgwAsn=65049
pCgwCidr=172.19.19.0/4

```

### b. ipsec.conf 설정

```
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
        left=${pEc2Eth0Ip}
        leftid=${pTu1CgwOutsideIp}
        # Virtual Private Gateway
        right=${pTu1VgwOutsideIp}
        rightid=${pTu1VgwOutsideIp}
        auto=start
        mark=100
conn TU2
        # Customer Gateway
        left=${pEc2Eth0Ip}
        leftid=${pTu2CgwOutsideIp}
        # Virtual Private Gateway
        right=${pTu2VgwOutsideIp}
        rightid=${pTu2VgwOutsideIp}
        auto=start
        mark=200
        
EOF

```

### c. ipsec.secrets 설정

```
cat <<EOF > /etc/strongswan/ipsec.secrets
#
# /etc/strongswan/ipsec.secrets
#
${pTu1CgwOutsideIp} ${pTu1VgwOutsideIp} : PSK ${pTu1Psk}
${pTu2CgwOutsideIp} ${pTu2VgwOutsideIp} : PSK ${pTu2Psk}
EOF

```

### d. ipsec-vti.sh 설정

```
cat <<EOF > /etc/strongswan/ipsec-vti.sh
#!/bin/bash
#
# /etc/strongswan/ipsec-vti.sh
#

IP=$(which ip)
IPTABLES=$(which iptables)

PLUTO_MARK_OUT_ARR=(${PLUTO_MARK_OUT//// })
PLUTO_MARK_IN_ARR=(${PLUTO_MARK_IN//// })

case "$PLUTO_CONNECTION" in
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

case "${PLUTO_VERB}" in
	up-client)
	#$IP tunnel add ${VTI_INTERFACE} mode vti local ${PLUTO_ME} remote ${PLUTO_PEER} okey ${PLUTO_MARK_OUT_ARR[0]} ikey ${PLUTO_MARK_IN_ARR[0]}
	$IP link add ${VTI_INTERFACE} type vti local ${PLUTO_ME} remote ${PLUTO_PEER} okey ${PLUTO_MARK_OUT_ARR[0]} ikey ${PLUTO_MARK_IN_ARR[0]}
	sysctl -w net.ipv4.conf.${VTI_INTERFACE}.disable_policy=1
	sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=2 || sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=0
	$IP addr add ${VTI_LOCALADDR} remote ${VTI_REMOTEADDR} dev ${VTI_INTERFACE}
	$IP link set ${VTI_INTERFACE} up mtu 1436
	$IPTABLES -t mangle -I FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	$IPTABLES -t mangle -I INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
	$IP route flush table 220
	#/etc/init.d/bgpd reload || /etc/init.d/quagga force-reload bgpd
	;;
	down-client)
	#$IP tunnel del ${VTI_INTERFACE}
	$IP link del ${VTI_INTERFACE}
	$IPTABLES -t mangle -D FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	$IPTABLES -t mangle -D INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
	;;
esac

# Enable IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.eth0.disable_xfrm=1
sysctl -w net.ipv4.conf.eth0.disable_policy=1

EOF

```

### e. ipsec-vti.sh 파일 모드 변경

```
sudo chmod +x /etc/strongswan/ipsec-vti.sh
```

### 1.3 IPSec 실행
```

```

### 1.4 IPSec 연결 확인
```

```


## 2. BGP 설치


### 2.1 Quagga 설치

```
sudo yum update -y
sudo yum install quagga-0.99.22.4 -y


```

### 2.2 Quagga(BGPD) 설정

```
cat <<EOF > /etc/quagga/bgpd.conf
#
# /etc/quagga/bgpd.conf
#
router bgp ${pCgwAsn}

bgp router-id 169.254.100.2
neighbor 169.254.100.1 remote-as ${pVgwAsn}
neighbor 169.254.200.1 remote-as ${pVgwAsn}
network ${pCgwCidr}
EOF
```

### 2.3 Quagga(BGPD) 실행
```

```

### 2.3 BGP 연결 확인
```

```
