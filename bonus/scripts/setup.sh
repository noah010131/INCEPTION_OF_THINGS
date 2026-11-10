# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    setup.sh                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: chanyoung <chanyoung@student.42.fr>        +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/11/10 09:37:35 by chanyoung         #+#    #+#              #
#    Updated: 2026/11/10 09:38:02 by chanyoung        ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BONUS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLUSTER_NAME="iot-bonus"
CONTEXT="k3d-$CLUSTER_NAME"
MODE="${1:-install}"
case "$MODE" in
  install|--skip-install|--sync) ;;
  *) echo "Usage: bash $0 [--skip-install|--sync]" >&2; exit 1 ;;
esac
trap 'echo "Setup failed at line $LINENO. Check pods/events in context k3d-iot-bonus." >&2' ERR

# Run inside a Debian/Ubuntu VM, as required by the subject.
if [[ "$MODE" == install ]]; then
  [[ "$(uname -s)" == Linux ]] || {
    echo "Run this script inside your Debian/Ubuntu VM." >&2; exit 1;
  }
  SUDO=()
  if [[ "$EUID" -ne 0 ]]; then SUDO=(sudo); fi
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y curl ca-certificates git docker.io openssl
  "${SUDO[@]}" systemctl enable --now docker
  case "$(uname -m)" in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "Unsupported architecture" >&2; exit 1 ;;
  esac
  INSTALL_TMP="$(mktemp -d)"
  trap 'rm -rf -- "$INSTALL_TMP"' EXIT
  if ! command -v kubectl >/dev/null; then
    VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSL "https://dl.k8s.io/release/$VERSION/bin/linux/$ARCH/kubectl" -o "$INSTALL_TMP/kubectl"
    "${SUDO[@]}" install -m 755 "$INSTALL_TMP/kubectl" /usr/local/bin/kubectl
  fi
  if ! command -v k3d >/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh -o "$INSTALL_TMP/k3d-install.sh"
    "${SUDO[@]}" bash "$INSTALL_TMP/k3d-install.sh"
  fi
  if ! command -v helm >/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$INSTALL_TMP/helm-install.sh"
    "${SUDO[@]}" bash "$INSTALL_TMP/helm-install.sh"
  fi
  if ! docker info >/dev/null 2>&1; then
    "${SUDO[@]}" usermod -aG docker "$(id -un)"
    printf -v REENTER 'bash %q --skip-install' "$SCRIPT_DIR/setup.sh"
    exec sg docker -c "$REENTER"
  fi
fi

for tool in docker k3d kubectl helm openssl; do
  command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
docker info >/dev/null

# All operations target the bonus cluster, even if p3 is the current context.
k() { kubectl --context "$CONTEXT" "$@"; }
if [[ "$MODE" == --sync ]]; then
  # Fail before creating an Application if the public repository is unavailable.
  REPO_URL="$(k create --dry-run=client -f "$BONUS_DIR/confs/argocd/application.yaml" -o jsonpath='{.spec.source.repoURL}')"
  k -n argocd exec deployment/argocd-repo-server -- \
    git ls-remote --exit-code "$REPO_URL" refs/heads/main >/dev/null
  k apply -f "$BONUS_DIR/confs/argocd/application.yaml"
  k -n argocd annotate application playground argocd.argoproj.io/refresh=hard --overwrite
  k -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced application/playground --timeout=600s
  k -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application/playground --timeout=600s
  k -n dev rollout status deployment/playground-deployment --timeout=300s
  echo "GitLab -> Argo CD -> dev synchronization is ready."
  exit 0
fi

if ! k3d cluster list --no-headers | awk -v name="$CLUSTER_NAME" \
  '$1 == name {found=1} END {exit !found}'; then
  k3d cluster create "$CLUSTER_NAME" --wait
fi
k3d kubeconfig merge "$CLUSTER_NAME" --kubeconfig-switch-context=false >/dev/null
k wait --for=condition=Ready nodes --all --timeout=300s
k apply -f "$BONUS_DIR/confs/namespaces.yaml"

# Generate once: rerunning setup must preserve database/object-storage passwords.
if ! k -n gitlab get secret gitlab-local-credentials >/dev/null 2>&1; then
  k -n gitlab create secret generic gitlab-local-credentials \
    --from-literal=postgres-password="$(openssl rand -hex 24)" \
    --from-literal=storage-password="$(openssl rand -hex 24)"
fi
STORAGE_PASSWORD="$(k -n gitlab get secret gitlab-local-credentials -o jsonpath='{.data.storage-password}' | base64 -d)"
CONNECTION="$(cat <<EOF
provider: AWS
region: us-east-1
aws_access_key_id: iot-storage
aws_secret_access_key: $STORAGE_PASSWORD
aws_signature_version: 4
host: minio.gitlab.svc.cluster.local
endpoint: http://minio.gitlab.svc.cluster.local:9000
path_style: true
EOF
)"
S3_CONFIG="$(cat <<EOF
[default]
access_key = iot-storage
secret_key = $STORAGE_PASSWORD
host_base = minio.gitlab.svc.cluster.local:9000
host_bucket = minio.gitlab.svc.cluster.local:9000
use_https = False
bucket_location = us-east-1
signature_v2 = False
EOF
)"
k -n gitlab create secret generic gitlab-object-storage \
  --from-literal=connection="$CONNECTION" --from-literal=config="$S3_CONFIG" \
  --dry-run=client -o yaml | k apply -f -
unset STORAGE_PASSWORD CONNECTION S3_CONFIG
k apply -f "$BONUS_DIR/confs/gitlab-dependencies.yaml"
for dependency in postgresql redis minio; do
  k -n gitlab rollout status "deployment/$dependency" --timeout=600s
done
k -n gitlab wait --for=condition=Complete job/gitlab-storage-buckets --timeout=300s

helm repo add gitlab https://charts.gitlab.io/ --force-update
helm repo update gitlab
# No --version on a new installation: the subject requires the latest stable GitLab.
# Preserve the installed chart on reruns; major upgrades need GitLab's upgrade path.
CHART_ARGS=()
INSTALLED_CHART="$(helm --kube-context "$CONTEXT" list -n gitlab --filter '^gitlab$' -q)"
if [[ -n "$INSTALLED_CHART" ]]; then
  INSTALLED_VERSION="$(helm --kube-context "$CONTEXT" list -n gitlab --filter '^gitlab$' -o json | \
    sed -n 's/.*"chart":"gitlab-\([^"]*\)".*/\1/p')"
  [[ -n "$INSTALLED_VERSION" ]] || { echo "Cannot determine installed chart version" >&2; exit 1; }
  CHART_ARGS=(--version "$INSTALLED_VERSION")
fi
helm --kube-context "$CONTEXT" upgrade --install gitlab gitlab/gitlab \
  -n gitlab -f "$BONUS_DIR/confs/gitlab-values.yaml" \
  "${CHART_ARGS[@]}" --timeout 30m --wait --wait-for-jobs

k apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
k wait --for=condition=Established crd/applications.argoproj.io --timeout=300s
for deployment in argocd-server argocd-repo-server; do
  k -n argocd rollout status "deployment/$deployment" --timeout=600s
done
k -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

cat <<'EOF'
Infrastructure is ready. Next steps are documented in bonus/README.md:
  1. Port-forward GitLab and sign in as root.
  2. Create the PUBLIC project root/chanyoung-iot (empty, default branch main).
  3. Push this repository, including bonus/confs/app, to that project.
  4. Run: bash bonus/scripts/setup.sh --sync

GitLab: kubectl --context k3d-iot-bonus -n gitlab port-forward --address 0.0.0.0 svc/gitlab-webservice-default 8081:8181
Argo CD: kubectl --context k3d-iot-bonus -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443
EOF
