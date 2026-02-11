#!/bin/bash
set -e

DOMAIN="k3s.oruro.gob.bo"
EMAIL="admin@oruro.gob.bo"

echo "🔄 Actualizando sistema..."
apt update -y
apt install -y curl wget ufw

echo "🔥 Instalando K3s..."
curl -sfL https://get.k3s.io | sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

echo "⏳ Esperando nodo listo..."
kubectl wait --for=condition=Ready node/$(hostname) --timeout=5m

echo "📦 Instalando Helm..."
if ! command -v helm &> /dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "📦 Instalando cert-manager..."
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
    email: ${EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-http
    solvers:
    - http01:
        ingress:
          class: traefik
EOF

echo "📦 Instalando Rancher..."
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --create-namespace \
  --set hostname=${DOMAIN} \
  --set bootstrapPassword=admin \
  --set ingress.tls.source=cert-manager \
  --set ingress.extraAnnotations."cert-manager\.io/cluster-issuer"=letsencrypt-http

echo "⏳ Esperando Rancher..."
kubectl -n cattle-system rollout status deploy/rancher --timeout=15m

echo "🔎 Esperando certificado..."
sleep 20

kubectl -n cattle-system get certificate

echo ""
echo "=================================================="
echo "✅ Rancher debería quedar accesible en:"
echo "👉 https://${DOMAIN}"
echo "=================================================="
