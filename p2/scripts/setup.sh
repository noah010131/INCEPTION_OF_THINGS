# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    setup.sh                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: chanypar <chanypar@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/19 10:15:07 by chanypar          #+#    #+#              #
#    Updated: 2026/10/19 19:06:19 by chanypar         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #


#!/usr/bin/env bash
set -euo pipefail

echo "=== Installing K3s ==="

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y curl ca-certificates

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

# App 1, App 2, App 3
for app in app1 app2 app3; do
  echo "Deploying $app..."

  k3s kubectl apply -f /vagrant/confs/$app/configmap.yaml
  k3s kubectl apply -f /vagrant/confs/$app/deployment.yaml
  k3s kubectl apply -f /vagrant/confs/$app/service.yaml
done

# 모든 Deployment가 준비될 때까지 대기
for app in app1 app2 app3; do
  k3s kubectl rollout status \
    deployment/$app-deployment --timeout=300s
done

echo "=== Configuring Ingress ==="

k3s kubectl apply -f /vagrant/confs/ingress.yaml
k3s kubectl apply -f /vagrant/confs/default-ingress.yaml

echo "=== Final Status ==="

k3s kubectl get nodes
k3s kubectl get deployments
k3s kubectl get pods
k3s kubectl get services
k3s kubectl get ingress

echo "=== Part 2 Ready! ==="
