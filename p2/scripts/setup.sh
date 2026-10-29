# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    setup.sh                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: chanyoung <chanyoung@student.42.fr>        +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/19 10:15:07 by chanypar          #+#    #+#              #
#    Updated: 2026/10/20 18:02:53 by chanyoung        ###   ########.fr        #
#                                                                              #
# **************************************************************************** #


#!/usr/bin/env bash
set -euo pipefail
# -e : 명령어가 실패하면 스크립트 중단
# -u : 선언되지 않은 변수를 사용하면 중단
# -o pipefail : 파이프라인의 중간 명령어가 실패해도 오류 처리

echo "=== Installing K3s ==="

export DEBIAN_FRONTEND=noninteractive
# 불필요한 질문 제거 

apt-get update -qq
# -qq : 불필요한 출력 최소화
apt-get install -y curl ca-certificates
# 서버 인증서 다운

# K3s Server 설치
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | sh -s - server \
    --node-ip 192.168.56.110
fi

systemctl enable --now k3s

# Kubernetes API 준비 대기
until k3s kubectl get nodes >/dev/null 2>&1; do
  echo "Waiting for Kubernetes API..."
  sleep 3
done

k3s kubectl wait \
  --for=condition=Ready \
  nodes --all --timeout=300s

echo "=== Deploying Applications ==="

# App 1, App 2, App 3(apply로 설정적용)
for app in app1 app2 app3; do
  echo "Deploying $app..."

  k3s kubectl apply -f /vagrant/confs/$app/configmap.yaml
  k3s kubectl apply -f /vagrant/confs/$app/deployment.yaml
  k3s kubectl apply -f /vagrant/confs/$app/service.yaml
done

# 순서 configmap -> deployment -> service:
# deployment에서 생성하는 pod 의 데이터를 가져옴, service는 순서 상관없음 

# 모든 Deployment가 준비될 때까지 대기 (rollout으로 배포가 되었는 지 체크)
for app in app1 app2 app3; do
  k3s kubectl rollout status \
    deployment/$app-deployment --timeout=300s
done

echo "=== Configuring Ingress ==="

k3s kubectl apply -f /vagrant/confs/ingress.yaml

echo "=== Final Status ==="

k3s kubectl get nodes
k3s kubectl get deployments
k3s kubectl get pods
k3s kubectl get services
k3s kubectl get ingress

echo "=== Part 2 Ready! ==="
