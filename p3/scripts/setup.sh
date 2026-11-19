#!/usr/bin/env bash

# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    setup.sh                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: chanyoung <chanyoung@student.42.fr>        +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/27 19:50:56 by chanyoung         #+#    #+#              #
#    Updated: 2026/11/16 16:57:00 by chanyoung        ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

set -euo pipefail

# 1. 경로 및 변수 설정

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P3_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="iot-p3"
CONTEXT="k3d-$CLUSTER_NAME"
APP_MANIFEST="$P3_DIR/confs/argocd/application.yaml"

# 기본 실행은 설치, --skip-install은 도구 설치 생략, --sync는 Application 연결만 수행
MODE="${1:-install}"
case "$MODE" in
  install|--skip-install|--sync) ;;
  *) echo "Usage: bash $0 [--skip-install|--sync]" >&2; exit 1 ;;
esac
trap 'echo "Setup failed at line $LINENO. Check pods/events in context k3d-iot-p3." >&2' ERR

# 2. 필수 프로그램 설치

# --skip-install 또는 --sync로 실행하면 설치 단계를 건너뜀
# apt-get과 systemctl을 사용하는 Debian VM에서 실행
if [[ "$MODE" == install ]]; then
  [[ "$(uname -s)" == Linux ]] || {
    echo "Run this script inside your Debian VM." >&2; exit 1;
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
    rm -rf -- "$INSTALL_TMP"
    trap - EXIT
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

# 모든 kubectl 명령에서 동일한 context를 명시
k() { kubectl --context "$CONTEXT" "$@"; }

if [[ "$MODE" != --sync ]]; then

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
  # 현재 context는 유지
  k3d kubeconfig merge "$CLUSTER_NAME" \
    --kubeconfig-switch-context=false >/dev/null

  # Kubernetes Node 준비 대기
  k wait \
    --for=condition=Ready \
    nodes --all --timeout=300s

  # 5. Namespace 생성

  echo "=== Creating Namespaces ==="

  k apply -f "$P3_DIR/confs/namespaces.yaml"

  # 6. Argo CD 설치

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

fi

# 7. Argo CD Application 연결 및 배포 확인

echo "=== Configuring Argo CD Application ==="

# Application 생성 전에 repo-server에서 GitHub main 브랜치 조회
REPO_URL="$(k create --dry-run=client -f "$APP_MANIFEST" -o jsonpath='{.spec.source.repoURL}')"
k -n argocd exec deployment/argocd-repo-server -- \
  git ls-remote --exit-code "$REPO_URL" refs/heads/main >/dev/null

# Playground Deployment와 Service는 직접 배포하지 않음
# Argo CD가 GitHub의 p3/confs/app에서 가져와 자동 배포함
k apply -f "$APP_MANIFEST"
k -n argocd annotate application playground argocd.argoproj.io/refresh=hard --overwrite

# Git 상태와 일치하고 앱이 정상 상태가 될 때까지 대기
k -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/playground --timeout=600s
k -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/playground --timeout=600s
k -n dev rollout status deployment/playground-deployment --timeout=300s

echo "=== Final Status ==="

k -n argocd get application playground
k -n dev get pods

echo "GitHub -> Argo CD -> dev synchronization is ready."
