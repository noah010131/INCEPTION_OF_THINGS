# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    setup.sh                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: chanyoung <chanyoung@student.42.fr>        +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/11/10 09:37:35 by chanyoung         #+#    #+#              #
#    Updated: 2026/11/17 19:35:18 by chanyoung        ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash

set -euo pipefail

# 1. 경로 및 변수 설정

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BONUS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="iot-p3"
CONTEXT="k3d-$CLUSTER_NAME"
APP_MANIFEST="$BONUS_DIR/confs/argocd/application.yaml"

# 기본 실행은 설치, --skip-install은 도구 설치 생략, --sync는 Application 연결만 수행
MODE="${1:-install}"
case "$MODE" in
  install|--skip-install|--sync) ;;
  *) echo "Usage: bash $0 [--skip-install|--sync]" >&2; exit 1 ;;
esac
trap 'echo "Setup failed at line $LINENO. Check pods/events in context k3d-iot-p3." >&2' ERR

# 2. 필수 프로그램 설치

# --skip-install 또는 --sync로 실행하면 설치 단계를 건너뜀
# apt-get과 systemctl을 사용하는 Debian/Ubuntu VM에서 실행
if [[ "$MODE" == install ]]; then
  [[ "$(uname -s)" == Linux ]] || {
    echo "Run this script inside your Debian/Ubuntu VM." >&2; exit 1;
  }
  # root로 실행하면 sudo를 생략
  SUDO=()
  if [[ "$EUID" -ne 0 ]]; then SUDO=(sudo); fi

  echo "=== Installing Docker ==="

  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y curl ca-certificates git docker.io
  "${SUDO[@]}" systemctl enable --now docker

  # CPU 아키텍처에 맞는 Linux 실행 파일 선택
  case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "Unsupported architecture" >&2; exit 1 ;;
  esac

  # 설치 파일은 임시 디렉터리에 보관하고 스크립트 종료 시 삭제
  INSTALL_TMP="$(mktemp -d)"
  trap 'rm -rf -- "$INSTALL_TMP"' EXIT

  echo "=== Installing kubectl ==="

  if ! command -v kubectl >/dev/null 2>&1; then
    VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    # CPU 아키텍처에 맞는 kubectl 다운로드
    curl -fsSL \
      "https://dl.k8s.io/release/${VERSION}/bin/linux/${ARCH}/kubectl" \
      -o "$INSTALL_TMP/kubectl"

    # kubectl을 실행 가능한 파일로 설치
    "${SUDO[@]}" install -m 755 "$INSTALL_TMP/kubectl" /usr/local/bin/kubectl
  fi

  echo "=== Installing k3d ==="

  if ! command -v k3d >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh -o "$INSTALL_TMP/k3d-install.sh"
    "${SUDO[@]}" bash "$INSTALL_TMP/k3d-install.sh"
  fi

  # Docker 그룹 권한이 아직 적용되지 않았다면
  # 그룹을 추가하고 해당 권한으로 설치 과정 재진입
  if ! docker info >/dev/null 2>&1; then
    echo "=== Configuring Docker Permissions ==="

    # 현재 사용자를 docker 그룹에 추가
    "${SUDO[@]}" usermod -aG docker "$(id -un)"

    # 경로의 공백과 특수문자를 보존하고 --skip-install로 다시 실행
    printf -v REENTER 'bash %q --skip-install' "$SCRIPT_DIR/setup.sh"
    exec sg docker -c "$REENTER"
  fi
fi

# 3. 필수 프로그램 및 Docker 확인

echo "=== Checking Docker ==="

# 설치를 생략한 경우에도 필요한 프로그램이 있는지 확인
for tool in docker k3d kubectl; do
  command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done

# 실제 Docker Daemon에 연결할 수 있는지 확인
docker info >/dev/null

# Bonus는 P3 클러스터를 재사용
# 모든 kubectl 명령에서 동일한 context를 명시
k() { kubectl --context "$CONTEXT" "$@"; }

# GitLab 프로젝트 생성과 최초 push 이후 --sync로 실행하는 별도 단계
if [[ "$MODE" == --sync ]]; then
  echo "=== Configuring Argo CD Application ==="

  # Application 생성 전에 repo-server에서 공개 저장소의 main 브랜치 조회
  # GitLab 프로젝트가 없거나 비공개이면 여기서 중단
  REPO_URL="$(k create --dry-run=client -f "$APP_MANIFEST" -o jsonpath='{.spec.source.repoURL}')"
  k -n argocd exec deployment/argocd-repo-server -- \
    git ls-remote --exit-code "$REPO_URL" refs/heads/main >/dev/null

  # Playground Deployment와 Service는 직접 배포하지 않음
  # Argo CD가 GitLab의 bonus/confs/app에서 가져와 자동 배포함
  k apply -f "$APP_MANIFEST"
  k -n argocd annotate application playground argocd.argoproj.io/refresh=hard --overwrite

  # Git 상태와 일치하고 앱이 정상 상태가 될 때까지 대기
  k -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/playground --timeout=600s
  k -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/playground --timeout=600s
  k -n dev rollout status deployment/playground-deployment --timeout=300s

  echo "=== Final Status ==="

  k -n argocd get application playground
  k -n dev get pods

  echo "GitLab -> Argo CD -> dev synchronization is ready."
  exit 0
fi

# 4. k3d 클러스터 생성

echo "=== Creating k3d Cluster ==="

# 같은 이름의 클러스터가 있으면 재사용
if ! k3d cluster list --no-headers | awk -v name="$CLUSTER_NAME" \
  '$1 == name {found=1} END {exit !found}'; then
  # port-forward만 사용하므로 Ingress와 ServiceLB는 실행하지 않음
  # CoreDNS/PVC 저장소와 자원 확인용 metrics-server는 기본 설정 유지
  # Pod 컨테이너별 로그는 약 10MiB씩 최대 3개로 회전
  k3d cluster create "$CLUSTER_NAME" \
    --k3s-arg '--disable=traefik@server:*' \
    --k3s-arg '--disable=servicelb@server:*' \
    --k3s-arg '--kubelet-arg=container-log-max-size=10Mi@server:*' \
    --k3s-arg '--kubelet-arg=container-log-max-files=3@server:*' \
    --wait
fi

# k3d 클러스터의 접속 정보를 kubeconfig에 병합
# p3에서 사용하던 현재 context는 유지
k3d kubeconfig merge "$CLUSTER_NAME" \
  --kubeconfig-switch-context=false >/dev/null

# Kubernetes Node 준비 대기
k wait \
  --for=condition=Ready \
  nodes --all --timeout=300s

# 5. Namespace 생성

echo "=== Creating Namespaces ==="

k apply -f "$BONUS_DIR/confs/namespaces.yaml"

# 6. GitLab Omnibus 설치

echo "=== Installing GitLab Omnibus ==="

# GitLab PVC, Service, Deployment 생성
k apply \
  -f "$BONUS_DIR/confs/gitlab/pvc.yaml" \
  -f "$BONUS_DIR/confs/gitlab/service.yaml" \
  -f "$BONUS_DIR/confs/gitlab/deployment.yaml"

# GitLab이 정상적으로 실행될 때까지 대기 (최대 30분)
k rollout status deployment/gitlab -n gitlab --timeout=1800s

# 7. Argo CD 설치

echo "=== Installing Argo CD ==="

k apply -n argocd \
  --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Application CRD 준비 대기
k wait \
  --for=condition=Established \
  crd/applications.argoproj.io \
  --timeout=300s

# Argo CD 구성 요소 준비 대기
k rollout status \
  deployment/argocd-server \
  -n argocd --timeout=600s

k rollout status \
  deployment/argocd-repo-server \
  -n argocd --timeout=600s

k rollout status \
  statefulset/argocd-application-controller \
  -n argocd --timeout=600s

# 8. 최종 확인 및 다음 단계 안내

echo "=== Final Status ==="

k get nodes
k get namespaces
k get pods -n gitlab
k get pods -n argocd

# p3와 달리 로컬 GitLab의 프로젝트 생성 및 최초 push가 먼저 필요
# 저장소 준비 후 --sync로 Application을 생성
echo "=== Bonus Infrastructure Setup Finished! ==="

cat <<'EOF'
Infrastructure is ready:

  1. Port-forward GitLab and sign in as root.
  2. Create the PUBLIC group 'iot' and the PUBLIC project 'iot/playground'.
     Do not initialize the repository with a README.
  3. Push the Playground manifests to the GitLab project's main branch.
     Keep the repository structure:
       bonus/confs/app/deployment.yaml
       bonus/confs/app/service.yaml
  4. Verify the Argo CD Application repoURL:
     http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/iot/playground.git
  5. Run: bash bonus/scripts/setup.sh --sync

GitLab: kubectl --context k3d-iot-p3 -n gitlab port-forward --address 127.0.0.1 svc/gitlab-webservice-default 8081:8181
Argo CD: kubectl --context k3d-iot-p3 -n argocd port-forward --address 127.0.0.1 svc/argocd-server 8080:443
EOF
