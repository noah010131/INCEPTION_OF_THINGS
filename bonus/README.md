

# Bonus: local GitLab + K3d + Argo CD

과제 보너스는 로컬 GitLab, `gitlab` 네임스페이스, GitLab을 사용한 Part 3의 전체 동작을 요구한다. 공식 최신 GitLab도 요구하므로 최초 설치 시 공식 Helm 저장소의 최신 stable 차트를 사용한다. 2026-11-10 확인한 최신 버전은 chart `10.5.4` / GitLab `19.5.3`이다. 현재 values는 이 차트로 검증했다. 이후 차트의 breaking change는 확인이 필요하다.

`p3/`는 수정하지 않는다. 별도 클러스터 `iot-bonus` 안에 `argocd`, `dev`, `gitlab` 네임스페이스를 만든다.

```text
VM/host -> GitLab UI / Git HTTP (port-forward)
                         |
              public root/chanyoung-iot.git
                         |
              Argo CD polls bonus/confs/app
                         |
                 dev / playground:v1 or v2
```

`confs/gitlab-dependencies.yaml`은 최신 공식 차트에서 별도로 요구하는 PostgreSQL 17, Redis, S3 호환 MinIO를 같은 `gitlab` 네임스페이스에 설치한다. 각 데이터는 PVC에 보관하고 암호는 최초 실행 시 Kubernetes Secret으로 생성한다. 로컬 과제 환경을 위한 단일 인스턴스 구성이다. GitLab Runner 없이도 manifest commit → Argo CD 자동 배포가 동작한다.

## 1. VM에서 설치

Debian/Ubuntu VM에서 실행한다. 권장 VM 자원: CPU 4개 이상, RAM 16GB, 여유 디스크 40GB 이상. 기존 p3 VM의 4GB RAM은 이 구성을 동시에 실행하기에 부족하다. 이 폴더에는 별도 Vagrantfile을 두지 않았으므로 VM 생성과 자원 설정은 먼저 진행한다.

```bash
bash bonus/scripts/setup.sh
```

스크립트가 Docker, kubectl, k3d, Helm을 설치한다. 모두 이미 설치되어 있고 Docker 접근 권한도 있다면:

```bash
bash bonus/scripts/setup.sh --skip-install
```

설치에는 인터넷과 이미지 다운로드 시간이 필요하다. GitLab 준비는 최대 30분 기다린다. 재실행 시 기존 PVC·암호·설치된 GitLab 차트 버전을 유지한다. 최신 버전으로 올리는 작업은 GitLab의 공식 upgrade path에 따라 별도로 진행한다. 클러스터를 삭제하면 k3d 내부의 PVC 데이터도 잃을 수 있다.

## 2. GitLab 접속 및 저장소 준비

VM 터미널에서 아래 port-forward를 계속 실행해 둔다.

```bash
kubectl --context k3d-iot-bonus -n gitlab port-forward \
  --address 0.0.0.0 svc/gitlab-webservice-default 8081:8181
```

VM과 브라우저를 실행하는 호스트 각각의 `/etc/hosts`에 다음을 추가한다. VM 내부에서는 `127.0.0.1`, 호스트에서는 실제 VM IP를 사용한다. 예를 들어 VM IP가 `192.168.56.111`이라면:

```text
# VM /etc/hosts
127.0.0.1 gitlab.iot.local

# host /etc/hosts
192.168.56.111 gitlab.iot.local
```

호스트 브라우저에서 `http://gitlab.iot.local:8081`에 접속한다. 사용자 이름은 `root`, 초기 암호는 VM에서 확인한다.

```bash
kubectl --context k3d-iot-bonus -n gitlab get secret \
  gitlab-gitlab-initial-root-password -o jsonpath='{.data.password}' | base64 -d
echo
```

GitLab에서 **Create blank project**로 아래와 같이 만든다.

- Namespace: `root`
- Project slug: `chanyoung-iot` — 저장소 이름에 그룹원 로그인 `chanyoung` 포함
- Visibility: **Public**
- Initialize repository with a README: **해제**

이름/사용자를 바꾸면 `confs/argocd/application.yaml`의 `repoURL`도 맞춘다. Argo CD는 클러스터 내부 Service DNS로 GitLab에 접근하므로 클러스터 내부에는 `/etc/hosts` 설정이 필요 없다. GitLab 저장소 URL에는 `.git` 접미사를 유지한다.

GitLab 사용자 설정에서 만료일과 `write_repository` 권한을 가진 Personal Access Token을 만든다. 저장소 루트에서 아래 작업으로 **현재 작업 파일을 복사한 별도 Git 저장소**를 만든 후 push한다. 기존 GitHub remote와 main 브랜치에는 영향을 주지 않는다.

```bash
SEED_DIR="$(mktemp -d /tmp/iot-gitlab-seed.XXXXXX)"
git ls-files --cached --others --exclude-standard -z | \
  tar --null -T - -cf - | tar -xf - -C "$SEED_DIR"
git -C "$SEED_DIR" init -b main
git -C "$SEED_DIR" add .
git -C "$SEED_DIR" -c user.name=chanyoung -c user.email=chanyoung@student.42.fr \
  commit -m "Add IoT bonus GitOps manifests"
git -C "$SEED_DIR" remote add origin \
  http://gitlab.iot.local:8081/root/chanyoung-iot.git
git -C "$SEED_DIR" push -u origin main
```

인증 프롬프트에 사용자 `root`, 암호 대신 PAT를 입력한다. 토큰은 URL이나 YAML에 저장하지 않는다. 이 임시 복사본은 최초 push용이며, 이후에는 아래처럼 GitLab 저장소를 clone해서 작업한다. 같은 이름의 프로젝트가 이미 있다면 새로 초기화하지 말고 기존 저장소에서 변경을 commit/push한다.

## 3. Argo CD 연결

최초 push가 끝난 뒤 원래 프로젝트 루트에서 실행한다.

```bash
bash bonus/scripts/setup.sh --sync
```

이 단계는 Argo CD repo-server에서 공개 저장소의 `main` 브랜치를 조회한 다음 Application을 생성한다. 이후 `Synced`, `Healthy`, Deployment rollout 완료까지 확인한다. `dev`의 앱 manifest는 Argo CD가 GitLab에서 가져오며 스크립트가 직접 apply하지 않는다.

Argo CD 화면이 필요하면 별도 VM 터미널에서 실행한다.

```bash
kubectl --context k3d-iot-bonus -n argocd port-forward \
  --address 0.0.0.0 svc/argocd-server 8080:443
```

호스트에서 `https://<VM_IP>:8080`으로 접속한다. 자체 서명 인증서를 허용하고 사용자 `admin`과 다음 초기 암호로 로그인한다.

```bash
kubectl --context k3d-iot-bonus -n argocd get secret \
  argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
```

## 4. 평가: v1 → v2 자동 배포

VM의 별도 터미널에서 앱을 노출한다.

```bash
kubectl --context k3d-iot-bonus -n dev port-forward \
  --address 0.0.0.0 svc/playground-service 8888:80
```

VM에서 `curl http://localhost:8888/`로 `v1` 응답을 확인한다. 호스트에서는 `http://<VM_IP>:8888/`를 사용한다.

이후 VM에서 **로컬 GitLab 저장소**를 clone하고 변경한다.

```bash
git clone http://gitlab.iot.local:8081/root/chanyoung-iot.git /tmp/chanyoung-iot-demo
cd /tmp/chanyoung-iot-demo
sed -i 's|wil42/playground:v1|wil42/playground:v2|' bonus/confs/app/deployment.yaml
git add bonus/confs/app/deployment.yaml
git -c user.name=chanyoung -c user.email=chanyoung@student.42.fr commit -m "Deploy playground v2"
git push origin main
```

Argo CD의 기본 polling 때문에 반영에 몇 분 걸릴 수 있다. UI에서 Git revision, `Synced`, `Healthy`와 아래 이미지 변경을 확인한다.

```bash
kubectl --context k3d-iot-bonus -n argocd get application playground
kubectl --context k3d-iot-bonus -n dev get deployment playground-deployment \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
echo
```

Pod 교체로 앱 port-forward가 종료되면 다시 실행한 뒤 `curl http://localhost:8888/`로 `v2`를 확인한다. `kubectl set image`나 직접 apply 없이 **GitLab commit만으로** 바뀌는 것을 시연한다.

## 문제 확인

```bash
kubectl --context k3d-iot-bonus -n gitlab get pods,pvc,jobs
kubectl --context k3d-iot-bonus -n gitlab get events --sort-by=.lastTimestamp
kubectl --context k3d-iot-bonus -n argocd describe application playground
kubectl --context k3d-iot-bonus -n argocd logs deployment/argocd-repo-server --tail=100
```

저장소 조회 오류라면 Public 여부, `main` 브랜치, `.git` 접미사, `bonus/confs/app` 경로부터 확인한다. GitLab의 clone 버튼이 제공하는 기본 URL에는 port-forward 포트가 없으므로 이 문서의 `:8081` 주소를 사용한다. `Pending` 또는 `OOMKilled`가 있으면 VM의 자원과 PVC 상태를 확인한다.

## 참고

- [과제 원문 공개 사본: Bonus part, p.16](https://github.com/Mtigunit/42-inception-of-things/blob/main/iot.pdf) — 학교에서 제공한 subject 버전이 최종 기준이다.
- [공식 GitLab Helm 설치](https://docs.gitlab.com/charts/installation/deployment/)
- [공식 GitLab globals 설정](https://docs.gitlab.com/charts/charts/globals/)
- [Argo CD GitLab 저장소 연결과 .git 접미사](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/)

검증 범위: 공식 chart 10.5.4에 대한 Helm lint / template, YAML 파싱, Bash 문법. 실제 VM에서의 전체 설치와 v1 → v2 시연은 별도 실행이 필요하다.
