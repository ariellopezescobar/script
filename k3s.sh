#!/bin/bash
set -e

DOMAIN="k3s.oruro.gob.bo"
EMAIL="admin@oruro.gob.bo"

apt-get update -y
apt-get install -y curl wget bash ca-certificates gnupg lsb-release apt-transport-https

# Instalar K3s
curl -sfL https://get.k3s.io | sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

# Esperar nodo listo
kubectl wait --for=condition=Ready node/$(hostname) --timeout=5m

# Instalar Helm si no existe
if ! command -v helm &> /dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Instalar cert-manager
kubectl create namespace cert-manager || true
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.12.2/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=10m

# Crear ClusterIssuer Let's Encrypt
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

# Instalar Rancher (SIN privateCA, SIN cacerts)
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

kubectl create namespace cattle-system || true

helm upgrade --install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname=$DOMAIN \
  --set replicas=1 \
  --set ingress.tls.source=cert-manager \
  --set ingress.tls.certManagerIssuerName=letsencrypt-http \
  --set privateCA=false

# Esperar Rancher listo
kubectl -n cattle-system rollout status deployment rancher --timeout=30m

echo "✅ Rancher instalado correctamente en https://$DOMAIN"
