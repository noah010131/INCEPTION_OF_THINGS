
Part 3 환경 구성 흐름

1. setup.sh

① Docker 설치
② kubectl 설치
③ k3d 설치
④ docker info로 권한 확인 (소캣에 접근권한이 있는 지(Docker Daemon))
- 성공 시 ⑤로 진행
- 실패시:
	- docker 그룹에 사용자 추가
	- sg docker로 그룹 권한 적용
	- 다시 setup.sh 실행, --skip-install 옵션으로 1-3 건너뜀
⑤ k3d 클러스터 생성
⑥ Argo CD 설치 및 설정

구조:

Fedora VM
- Docker
	- k3d Cluster: iot-p3
    	- K3s Server Node
        	- Control Plane 기능
        	- Worker 기능

        	- argocd Namespace
            	- Argo CD Pods

            - dev Namespace
        		- Playground Pod