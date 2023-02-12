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
pTu1VgwIntsideIp=169.254.100.1

# IPSec Tunnel #2 Info
pTu2Psk=PqAwSeSrWtOyRyD
pTu2CgwOutsideIp=54.180.213.90
pTu2VgwOutsideIp=3.120.101.10
pTu2CgwInsideIp=169.254.200.2
pTu2VgwIntsideIp=169.254.200.1

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
[root@CGW ~]# strongswan statusall
Status of IKE charon daemon (strongSwan 5.7.2, Linux 5.10.157-139.675.amzn2.x86_64, x86_64):
  uptime: 9 minutes, since Dec 18 12:03:28 2022
  malloc: sbrk 2842624, mmap 0, used 1069088, free 1773536
  worker threads: 11 of 16 idle, 5/0/0/0 working, job queue: 0/0/0/0, scheduled: 10
  loaded plugins: charon pkcs11 tpm aesni aes des rc2 sha2 sha1 md4 md5 mgf1 random nonce x509 revocation constraints acert pubkey pkcs1 pkcs7 pkcs8 pkcs12 pgp dnskey sshkey pem openssl gcrypt fips-prf gmp curve25519 chapoly xcbc cmac hmac ctr ccm gcm curl attr kernel-netlink resolve socket-default farp stroke vici updown eap-identity eap-sim eap-aka eap-aka-3gpp eap-aka-3gpp2 eap-md5 eap-gtc eap-mschapv2 eap-dynamic eap-radius eap-tls eap-ttls eap-peap xauth-generic xauth-eap xauth-pam xauth-noauth dhcp led duplicheck unity counters
Listening IP addresses:
  172.16.81.4
  169.254.100.2
  169.254.200.2
Connections:
         TU1:  172.16.81.4...13.208.136.177  IKEv1, dpddelay=10s
         TU1:   local:  [13.208.48.253] uses pre-shared key authentication
         TU1:   remote: [13.208.136.177] uses pre-shared key authentication
         TU1:   child:  0.0.0.0/0 ::/0 === 0.0.0.0/0 ::/0 TUNNEL, dpdaction=restart
         TU2:  172.16.81.4...15.152.124.140  IKEv1, dpddelay=10s
         TU2:   local:  [13.208.48.253] uses pre-shared key authentication
         TU2:   remote: [15.152.124.140] uses pre-shared key authentication
         TU2:   child:  0.0.0.0/0 ::/0 === 0.0.0.0/0 ::/0 TUNNEL, dpdaction=restart
Security Associations (2 up, 0 connecting):
         TU2[2]: ESTABLISHED 9 minutes ago, 172.16.81.4[13.208.48.253]...15.152.124.140[15.152.124.140]
         TU2[2]: IKEv1 SPIs: fb982a7466cd2932_i* d3bef376d4ae6e5a_r, rekeying in 7 hours
         TU2[2]: IKE proposal: AES_CBC_128/HMAC_SHA1_96/PRF_HMAC_SHA1/MODP_1024
         TU2{2}:  INSTALLED, TUNNEL, reqid 2, ESP in UDP SPIs: c3ce6aaf_i c1849cad_o
         TU2{2}:  AES_CBC_128/HMAC_SHA1_96/MODP_1024, 7751 bytes_i, 6725 bytes_o (104 pkts, 6s ago), rekeying in 36 minutes
         TU2{2}:   0.0.0.0/0 === 0.0.0.0/0
         TU1[1]: ESTABLISHED 9 minutes ago, 172.16.81.4[13.208.48.253]...13.208.136.177[13.208.136.177]
         TU1[1]: IKEv1 SPIs: 101a950f3e59f54c_i* a2f071a5fe731d8c_r, rekeying in 7 hours
         TU1[1]: IKE proposal: AES_CBC_128/HMAC_SHA1_96/PRF_HMAC_SHA1/MODP_1024
         TU1{1}:  INSTALLED, TUNNEL, reqid 1, ESP in UDP SPIs: c103084b_i c8f6d27a_o
         TU1{1}:  AES_CBC_128/HMAC_SHA1_96/MODP_1024, 5255 bytes_i, 7920 bytes_o (126 pkts, 5s ago), rekeying in 35 minutes
         TU1{1}:   0.0.0.0/0 === 0.0.0.0/0
[root@CGW ~]#
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
[root@CGW ec2-user]# vtysh
CGW# sh ip route
```

결과 예제
```
[root@CGW ec2-user]# vtysh

Hello, this is Quagga (version 0.99.22.4).
Copyright 1996-2005 Kunihiro Ishiguro, et al.

CGW# sh ip route
Codes: K - kernel route, C - connected, S - static, R - RIP,
       O - OSPF, I - IS-IS, B - BGP, A - Babel,
       > - selected route, * - FIB route

K>* 0.0.0.0/0 via 172.16.81.1, eth0
B>* 10.81.0.0/16 [20/100] via 169.254.200.1, vti2, 00:00:19
C>* 127.0.0.0/8 is directly connected, lo
C>* 169.254.100.0/30 is directly connected, vti1
K>* 169.254.169.254/32 is directly connected, eth0
C>* 169.254.200.0/30 is directly connected, vti2
C>* 172.16.81.0/28 is directly connected, eth0
CGW# sh ip bgp
BGP table version is 0, local router ID is 169.254.100.2
Status codes: s suppressed, d damped, h history, * valid, > best, i - internal,
              r RIB-failure, S Stale, R Removed
Origin codes: i - IGP, e - EGP, ? - incomplete

   Network          Next Hop            Metric LocPrf Weight Path
*  10.81.0.0/16     169.254.100.1          100             0 64512 i
*>                  169.254.200.1          100             0 64512 i
*> 172.16.81.0/24   0.0.0.0                  0         32768 i

Total number of prefixes 2
CGW# sh ip bgp  neighbors
BGP neighbor is 169.254.100.1, remote AS 64512, local AS 64581, external link
  BGP version 4, remote router ID 169.254.100.1
  BGP state = Established, up for 00:00:27
  Last read 00:00:07, hold time is 30, keepalive interval is 10 seconds
  Neighbor capabilities:
    4 Byte AS: advertised and received
    Route refresh: advertised and received(old & new)
    Address family IPv4 Unicast: advertised and received
  Message statistics:
    Inq depth is 0
    Outq depth is 0
                         Sent       Rcvd
    Opens:                  3          1
    Notifications:          0          0
    Updates:                4          2
    Keepalives:           153        151
    Route Refresh:          0          0
    Capability:             0          0
    Total:                160        154
  Minimum time between advertisement runs is 30 seconds

 For address family: IPv4 Unicast
  Community attribute sent to this neighbor(both)
  1 accepted prefixes

  Connections established 2; dropped 1
  Last reset 00:00:36, due to
Local host: 169.254.100.2, Local port: 179
Foreign host: 169.254.100.1, Foreign port: 38895
Nexthop: 169.254.100.2
Nexthop global: fe80::5efe:ac10:5104
Nexthop local: ::
BGP connection: non shared network
Read thread: on  Write thread: off

BGP neighbor is 169.254.200.1, remote AS 64512, local AS 64581, external link
  BGP version 4, remote router ID 169.254.200.1
  BGP state = Established, up for 00:00:28
  Last read 00:00:08, hold time is 30, keepalive interval is 10 seconds
  Neighbor capabilities:
    4 Byte AS: advertised and received
    Route refresh: advertised and received(old & new)
    Address family IPv4 Unicast: advertised and received
  Message statistics:
    Inq depth is 0
    Outq depth is 0
                         Sent       Rcvd
    Opens:                  3          1
    Notifications:          0          0
    Updates:                2          2
    Keepalives:           153        151
    Route Refresh:          0          0
    Capability:             0          0
    Total:                158        154
  Minimum time between advertisement runs is 30 seconds

 For address family: IPv4 Unicast
  Community attribute sent to this neighbor(both)
  1 accepted prefixes

  Connections established 2; dropped 1
  Last reset 00:00:36, due to
Local host: 169.254.200.2, Local port: 179
Foreign host: 169.254.200.1, Foreign port: 45283
Nexthop: 169.254.200.2
Nexthop global: fe80::5efe:ac10:5104
Nexthop local: ::
BGP connection: non shared network
Read thread: on  Write thread: off

CGW#
```
