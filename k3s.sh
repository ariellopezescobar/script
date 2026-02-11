#!/bin/bash
set -e

DOMAIN="k3s.oruro.gob.bo"
EMAIL="admin@oruro.gob.bo"

apt update -y
apt install -y curl wget bash ca-certificates gnupg lsb-release apt-transport-https net-tools

# Instalar k3s
curl -sfL https://get.k3s.io | sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

kubectl wait --for=condition=Ready node/$(hostname) --timeout=5m

# Instalar Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Instalar cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.12.2/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=5m

# Crear ClusterIssuer
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-http
spec:
  acme:
    email: $EMAIL
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-http
    solvers:
    - http01:
        ingress:
          class: traefik
EOF

# Instalar Rancher
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

kubectl create namespace cattle-system || true

helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=$DOMAIN \
  --set bootstrapPassword=admin \
  --set ingress.ingressClassName=traefik \
  --set ingress.tls.source=cert-manager \
  --set ingress.extraAnnotations."cert-manager\.io/cluster-issuer"=letsencrypt-http \
  --set certmanager.enabled=false
