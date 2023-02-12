# Site-to-Site VPN 설정 (StrongSwan+Quagga)

## 0. 변수 설정


```
# CGW(EC2 Instance) Eth0
pCgwEth0Ip=172.19.19.10

# IPSec Tunnel #1 Info
pTu1Psk=PqAwSeSrWtOyRyD
pTu1CgwOutsideIp=54.180.213.90
pTu1VgwOutsideIp=3.69.86.199
pTu1CgwInsideIp=169.254.100.2
pTu1VgwInsideIp=169.254.100.1

# IPSec Tunnel #2 Info
pTu2Psk=PqAwSeSrWtOyRyD
pTu2CgwOutsideIp=54.180.213.90
pTu2VgwOutsideIp=3.120.101.10
pTu2CgwInsideIp=169.254.200.2
pTu2VgwInsideIp=169.254.200.1

# BGP Info
pCgwAsn=64582
pVgwAsn=65049
pCgwCidr=172.19.19.0/4
```

## 1. IPSec 설정 (StrongSwan)


### 1.1 StrongSwan 설치

```
sudo yum update -y
sudo amazon-linux-extras install -y epel
sudo yum install strongswan -y
```

#### a. ipsec.conf 설정

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
```

#### b. ipsec.secrets 설정

```
cat <<EOF > /etc/strongswan/ipsec.secrets
#
# /etc/strongswan/ipsec.secrets
#
${pTu1CgwOutsideIp} ${pTu1VgwOutsideIp} : PSK ${pTu1Psk}
${pTu2CgwOutsideIp} ${pTu2VgwOutsideIp} : PSK ${pTu2Psk}
EOF
```

#### c. ipsec-vti.sh 설정

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
# Disable IPv4 ICMP Redirect
sysctl -w net.ipv4.conf.eth0.accept_redirects=0
sysctl -w net.ipv4.conf.eth0.send_redirects=0


EOF
```

#### d. ipsec-vti.sh 파일 모드 변경

```
sudo chmod +x /etc/strongswan/ipsec-vti.sh
```

### 1.3 IPSec 실행
```
sudo systemctl enable --now strongswan
```

### 1.4 IPSec 연결 확인
```
strongswan statusall
```
결과 예제
```
h-4.2$ sudo strongswan statusall
Status of IKE charon daemon (strongSwan 5.7.2, Linux 5.10.165-143.735.amzn2.x86_64, x86_64):
  uptime: 25 hours, since Feb 11 02:27:21 2023
  malloc: sbrk 2961408, mmap 0, used 1188400, free 1773008
  worker threads: 11 of 16 idle, 5/0/0/0 working, job queue: 0/0/0/0, scheduled: 8
  loaded plugins: charon pkcs11 tpm aesni aes des rc2 sha2 sha1 md4 md5 mgf1 random nonce x509 revocation constraints acert pubkey pkcs1 pkcs7 pkcs8 pkcs12 pgp dnskey sshkey pem openssl gcrypt fips-prf gmp curve25519 chapoly xcbc cmac hmac ctr ccm gcm curl attr kernel-netlink resolve socket-default farp stroke vici updown eap-identity eap-sim eap-aka eap-aka-3gpp eap-aka-3gpp2 eap-md5 eap-gtc eap-mschapv2 eap-dynamic eap-radius eap-tls eap-ttls eap-peap xauth-generic xauth-eap xauth-pam xauth-noauth dhcp led duplicheck unity counters
Listening IP addresses:
  172.19.19.10
  169.254.100.2
  169.254.200.2
Connections:
         TU1:  172.19.19.10...3.69.86.199  IKEv1, dpddelay=10s
         TU1:   local:  [54.180.213.90] uses pre-shared key authentication
         TU1:   remote: [3.69.86.199] uses pre-shared key authentication
         TU1:   child:  0.0.0.0/0 === 0.0.0.0/0 TUNNEL, dpdaction=restart
         TU2:  172.19.19.10...3.120.101.10  IKEv1, dpddelay=10s
         TU2:   local:  [54.180.213.90] uses pre-shared key authentication
         TU2:   remote: [3.120.101.10] uses pre-shared key authentication
         TU2:   child:  0.0.0.0/0 === 0.0.0.0/0 TUNNEL, dpdaction=restart
Security Associations (2 up, 0 connecting):
         TU2[10]: ESTABLISHED 2 hours ago, 172.19.19.10[54.180.213.90]...3.120.101.10[3.120.101.10]
         TU2[10]: IKEv1 SPIs: 7c77d78ab9eef6bd_i* 708be1a3b210dd85_r, rekeying in 5 hours
         TU2[10]: IKE proposal: AES_CBC_128/HMAC_SHA1_96/PRF_HMAC_SHA1/MODP_1024
         TU2{69}:  INSTALLED, TUNNEL, reqid 2, ESP in UDP SPIs: c0d40c9f_i cec9b0fe_o
         TU2{69}:  AES_CBC_128/HMAC_SHA1_96/MODP_1024, 21793190 bytes_i, 170821 bytes_o (3219 pkts, 5s ago), rekeying in 17 minutes
         TU2{69}:   0.0.0.0/0 === 0.0.0.0/0
         TU1[9]: ESTABLISHED 2 hours ago, 172.19.19.10[54.180.213.90]...3.69.86.199[3.69.86.199]
         TU1[9]: IKEv1 SPIs: 75bec5eb3e24fd75_i* 76585525753ddde7_r, rekeying in 5 hours
         TU1[9]: IKE proposal: AES_CBC_128/HMAC_SHA1_96/PRF_HMAC_SHA1/MODP_1024
         TU1{70}:  INSTALLED, TUNNEL, reqid 1, ESP in UDP SPIs: c986e398_i cc589d58_o
         TU1{70}:  AES_CBC_128/HMAC_SHA1_96/MODP_1024, 10904720 bytes_i, 18204 bytes_o (296 pkts, 5s ago), rekeying in 22 minutes
         TU1{70}:   0.0.0.0/0 === 0.0.0.0/0
```


## 2. BGP 설정 (Quagga)



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
sudo systemctl start zebra
sudo systemctl enable zebra
sudo systemctl start bgpd
sudo systemctl enable bgpd
sudo chmod -R 777 /etc/quagga/
```

### 2.3 BGP 연결 확인

```
sh-4.2$ sudo vtysh
CGW# sh ip route
CGW# sh ip bgp
```

결과 예제
```
sh-4.2$ sudo vtysh

Hello, this is Quagga (version 0.99.22.4).
Copyright 1996-2005 Kunihiro Ishiguro, et al.

ip-172-19-19-10.ap-northeast-2.compute.internal# sh ip ro
Codes: K - kernel route, C - connected, S - static, R - RIP,
       O - OSPF, I - IS-IS, B - BGP, A - Babel,
       > - selected route, * - FIB route

K>* 0.0.0.0/0 via 172.19.19.1, eth0
B>* 10.49.0.0/24 [20/100] via 169.254.200.1, vti2, 1d01h48m
B>* 10.49.1.0/24 [20/100] via 169.254.200.1, vti2, 1d01h48m
B>* 10.49.2.0/24 [20/100] via 169.254.200.1, vti2, 1d01h48m
C>* 127.0.0.0/8 is directly connected, lo
C>* 169.254.100.0/30 is directly connected, vti1
K>* 169.254.169.254/32 is directly connected, eth0
C>* 169.254.200.0/30 is directly connected, vti2
C>* 172.19.19.0/28 is directly connected, eth0

ip-172-19-19-10.ap-northeast-2.compute.internal# sh ip bgp
BGP table version is 0, local router ID is 169.254.100.2
Status codes: s suppressed, d damped, h history, * valid, > best, i - internal,
              r RIB-failure, S Stale, R Removed
Origin codes: i - IGP, e - EGP, ? - incomplete

   Network          Next Hop            Metric LocPrf Weight Path
*  10.49.0.0/24     169.254.100.1          100             0 65049 i
*>                  169.254.200.1          100             0 65049 i
*  10.49.1.0/24     169.254.100.1          100             0 65049 i
*>                  169.254.200.1          100             0 65049 i
*  10.49.2.0/24     169.254.100.1          100             0 65049 i
*>                  169.254.200.1          100             0 65049 i
*> 172.19.19.0/24   0.0.0.0                  0         32768 i

Total number of prefixes 5
ip-172-19-19-10.ap-northeast-2.compute.internal#
```
