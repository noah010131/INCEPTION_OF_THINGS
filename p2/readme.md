
Part 2 VM 설치 및 환경 구성 흐름

1. Vagrantfile
- 1. Vagrantfile 읽기 (Vagrant.configure("2"))
- 2. 기본 이미지와 아키텍쳐 설정
- 3. VM 정의 (config.vm.define NAME)
- 4. VM 네트워크 및 하드웨어 설정
- 5. Provisioning 실행

2. setup.sh
- 1. 설치환경 준비
	apt-get update & apt-get install ca-certificate
- 2. K3s 서버 설치
	curl -sfL https://get.k3s.io
	--node-ip : 사용할 주소 지정 (쿠버네티스 노드)
- 3. 쿠버네티스 대기 (API Server 응답 확인 & node 준비 확인)
- 4. app 생성 및 배포
	k3s kubectl apply (순서 configmap -> deployment -> service)
	k3s kubectl rollout (배포 완료 체크)
- 5. Ingress 라우팅 규칙 적용

네트워크 리스트 
ip -br addr

인터페이스		IPv4 주소					역할
lo				127.0.0.1/8					자기 자신과 통신하는 Loopback 
eth0			10.0.2.15/24				VirtualBox NAT 네트워크
eth1			192.168.56.110/24			VirtualBox Host-only 네트워크
flannel.1		10.42.0.0/32				K3s Flannel의 VXLAN 인터페이스 (Kubernetes Node에 있는 Pod들이 서로 통신할 수 있도록 네트워크를 구성하는 역할)
cni0			10.42.0.1/24				Pod들을 연결하는 Linux Bridge
veth... 10개	호스트 쪽 IPv6 주소 표시	Pod 네트워크와 연결되는 가상 인터페이스

cni 네트워크: traefik 가 특정 pod로 요청을 보낼 때 실질적으로 사용하는 네트워크 
veth (virtual ethernet): 두 네트워크의 인터페이스를 연결하는 가상의 케이블(host 하나 guest 하나)
*Cluster IP: Kubernetes Service의 가상 IP 

host-guest 관계도

MAC > VM > Kubernetes Pod
MAC <-> VM: Virtual Box의 가상 네트워크 카드로 연결
VM <-> Kubernetes Pod: CNI를 거쳐 host veth <-> pod eth0 연결

네트워크 연결 흐름(hostonly -> pod)
Mac -> eth1 -> traekfik(특정 app service) -> eth0 |-> veth -> (cluster ip) -> cni0 -> veth |-> eth0 -> pod

