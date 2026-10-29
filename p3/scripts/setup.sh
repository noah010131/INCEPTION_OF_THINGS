# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    setup.sh                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: chanyoung <chanyoung@student.42.fr>        +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/27 19:50:56 by chanyoung         #+#    #+#              #
#    Updated: 2026/10/29 19:37:22 by chanyoung        ###   ########.fr        #
#                                                                              #
# **************************************************************************** #


#!/usr/bin/env bash
set -euo pipefail

# 1. 경로 및 변수 설정

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P3_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="iot-p3"
APP_MANIFEST="$P3_DIR/confs/argocd/application.yaml"

# 2. 필수 프로그램 설치

# --skip-install로 재실행하면 설치 단계를 건너뜀
if [[ "${1:-}" != "--skip-install" ]]; then

  echo "=== Installing Docker ==="
  
  sudo apt-get update
  sudo apt-get install -y curl ca-certificates git docker.io
  sudo systemctl enable --now docker

  echo "=== Installing kubectl ==="

  if ! command -v kubectl >/dev/null 2>&1; then

    # CPU 아키텍처 확인
    case "$(uname -m)" in
      aarch64) ARCH="arm64" ;;
      x86_64)  ARCH="amd64" ;;
      *) echo "Unsupported architecture"; exit 1 ;;
    esac

    VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"

    # CPU 아키텍처에 맞는 kubectl 다운로드
    curl -fsSL \
      "https://dl.k8s.io/release/${VERSION}/bin/linux/${ARCH}/kubectl" \
      -o /tmp/kubectl

    # kubectl을 실행 가능한 파일로 설치
    sudo install -m 755 /tmp/kubectl /usr/local/bin/kubectl
    rm -f /tmp/kubectl
  fi

  echo "=== Installing k3d ==="

  if ! command -v k3d >/dev/null 2>&1; then
    curl -fsSL \
      https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
  fi

  # Docker 그룹 권한이 아직 적용되지 않았다면
  # 그룹을 추가하고 해당 권한으로 설치 과정 재진입
  if ! docker info >/dev/null 2>&1; then
    echo "=== Configuring Docker Permissions ==="

    # 현재 사용자를 docker 그룹에 추가
    sudo usermod -aG docker "$(id -un)"

    # docker 그룹 권한으로 setup.sh를 다시 실행
    exec sg docker -c "bash '$SCRIPT_DIR/setup.sh' --skip-install"
  fi
fi

# 3. Docker 확인

echo "=== Checking Docker ==="

# 실제 Docker Daemon에 연결할 수 있는지 확인
docker info >/dev/null

# 4. k3d 클러스터 생성

echo "=== Creating k3d Cluster ==="

if ! k3d cluster list |
  awk -v name="$CLUSTER_NAME" \
    'NR > 1 && $1 == name {found=1} END {exit !found}'; then

  k3d cluster create "$CLUSTER_NAME"
fi

# kubectl이 사용할 클러스터 선택
k3d kubeconfig merge "$CLUSTER_NAME" \
  --kubeconfig-switch-context

# Kubernetes Node 준비 대기
kubectl wait \
  --for=condition=Ready \
  nodes --all --timeout=300s

# 5. Namespace 생성

echo "=== Creating Namespaces ==="

kubectl apply -f "$P3_DIR/confs/namespaces.yaml"

# 6. Argo CD 설치

echo "=== Installing Argo CD ==="

kubectl apply -n argocd \
  --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Application CRD 준비 대기
kubectl wait \
  --for=condition=Established \
  crd/applications.argoproj.io \
  --timeout=300s

# Argo CD 구성 요소 준비 대기
kubectl rollout status \
  deployment/argocd-server \
  -n argocd --timeout=600s

kubectl rollout status \
  deployment/argocd-repo-server \
  -n argocd --timeout=600s

kubectl rollout status \
  statefulset/argocd-application-controller \
  -n argocd --timeout=600s

# 7. Argo CD Application 생성

echo "=== Configuring Argo CD Application ==="

if [[ ! -f "$APP_MANIFEST" ]] ||
   grep -q 'YOUR_USERNAME' "$APP_MANIFEST"; then
  echo "ERROR: Configure your GitHub URL in application.yaml"
  exit 1
fi

kubectl apply -f "$APP_MANIFEST"

# Playground Deployment와 Service는 직접 배포하지 않음
# Argo CD가 GitHub에서 가져와 자동 배포함

# 8. 최종 확인

echo "=== Final Status ==="

kubectl get nodes
kubectl get namespaces
kubectl get applications -n argocd
kubectl get pods -n dev

echo "=== Part 3 Setup Finished! ==="
