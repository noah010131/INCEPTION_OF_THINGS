
1. 사양: 메모리 8기가, 저장공간 25기가

  Helm vs Omnibus

  Omnibus 기반 단일 컨테이너: GitLab의 여러 서비스를 하나의 컨테이너 안에서 실행
  - 가벼움  
  - 테스트환경 적합

  공식 GitLab Helm Chart: GitLab의 여러 서비스를 Kubernetes의 독립적인 워크로드로 배포
  - 고가용성
  - 자동화배포이력 관리

2. setup.sh 순서

1. Docker 설치
2. kubectl + k3d 설치
3. k3d cluster 설치
4. Namespace 생성
5. Gitlab Omnibus 설치 (gitlab.yaml)
  - PVC GitLab 설정과 데이터 저장
  - Service Kubernetes 내부에서 GitLab에 접근
  - Deployment GitLab Pod 생성 및 관리
6. Argo CD 설치
------메뉴얼 설정 -----
7. setup.sh —sync(최초 연결 시)
8. GitLab 저장소 접근 확인
9. Argo CD Application 생성 및 배포
10. Playground 자동 배포 (app/)
11. Synced / Healthy 상태 확인


메뉴얼 설정:설치 후 실제 Ready 상태 확인:
```bash
kubectl --context k3d-iot-bonus -n gitlab rollout status deployment/gitlab --timeout=1800s
kubectl --context k3d-iot-bonus -n gitlab get pods -l app=iot-gitlab
kubectl --context k3d-iot-bonus -n gitlab exec deployment/gitlab -- \
  curl --noproxy '*' -fsS --max-time 4 -H 'Host: gitlab.iot.local:8081' \
  'http://127.0.0.1:8081/-/readiness?all=1'
```



3. gitlab

1.PersistentVolumeClaim (PVC)	GitLab 데이터 영구 저장(pod 교체 시 데이터 유지)
2	Service	GitLab에 접속할 네트워크 주소 제공
3	Deployment	GitLab Omnibus 컨테이너 생성 및 관리
  - env 생성(포트, 백그리운드 작업제한, 불필요한 설정 제거)
  - PVC 설정(3개: 설정, 로그, 데이터베이스)
  - Probe 설정(exec방식: 컨테이너 내부에서 실행)
  - 설정한 볼륨 연결

4. 상호작용 방식

네트워크 연결 방식(Argo CD -> gitlab):
Argo CD
   ↓
GitLab Service :8181
   ↓
GitLab Pod :8081
   ↓
GitLab Omnibus

테스트 흐름도:
사용자
  │
  │ deployment.yaml 수정
  │ git commit / git push
  ↓
GitLab 저장소 (iot/playground)
  │
  │ main 브랜치에 설정 저장
  ↓
Argo CD Repo Server
  │
  │ GitLab 저장소 조회 (2-3분 마다)
  ↓
Argo CD Application Controller
  │
  │ Git 설정과 실제 Kubernetes 상태 비교
  ↓
Kubernetes API Server
  │
  │ Deployment / Service 생성·갱신
  ↓
dev Namespace
  │
  ↓
Playground Deployment
  │
  ↓
Playground Pod
(wil42/playground:v1 → v2)
  │
  ↓
Synced / Healthy





