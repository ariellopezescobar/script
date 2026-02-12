#!/bin/bash
set -e

DOMAIN="k3s.oruro.gob.bo"
EMAIL="admin@oruro.gob.bo"

echo "🔄 Actualizando sistema..."
apt-get update && apt-get upgrade -y
apt-get install -y curl wget bash ca-certificates gnupg lsb-release apt-transport-https net-tools ufw nmap

echo "🚀 Instalando K3s..."
curl -sfL https://get.k3s.io | sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

echo "⏳ Esperando nodo Ready..."
kubectl wait --for=condition=Ready node/$(hostname) --timeout=5m

echo "📦 Instalando Helm..."
if ! command -v helm &> /dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "📦 Instalando cert-manager..."
kubectl create namespace cert-manager || true
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.12.2/cert-manager.yaml

kubectl -n cert-manager rollout status deploy/cert-manager --timeout=5m
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=5m

echo "🔐 Creando ClusterIssuer Let's Encrypt..."

cat <<EOF | kubectl apply -f -
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

echo "📦 Instalando Rancher..."

helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update

kubectl create namespace cattle-system || true

helm upgrade --install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=$DOMAIN \
  --set replicas=1 \
  --set bootstrapPassword=admin \
  --set ingress.tls.source=cert-manager \
  --set ingress.tls.certManagerIssuerName=letsencrypt-http

echo "⏳ Esperando despliegue Rancher..."
kubectl -n cattle-system rollout status deploy/rancher --timeout=30m

echo "🔎 Esperando certificado..."
kubectl -n cattle-system wait --for=condition=Ready certificate/tls-rancher-ingress --timeout=15m || true

echo ""
echo "✅ Rancher instalado correctamente"
echo "🌐 Accede a: https://$DOMAIN"
echo "👤 Usuario: admin"
echo "🔑 Password: admin"
