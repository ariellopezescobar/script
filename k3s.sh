#!/bin/bash
set -e
DOMAIN="k3s.oruro.gob.bo"
EMAIL="admin@oruro.gob.bo"
apt-get update && apt-get upgrade -y
apt-get install -y curl wget bash ca-certificates gnupg lsb-release apt-transport-https net-tools ufw nmap
curl -sfL https://get.k3s.io | sh -
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
sleep 10
kubectl wait --for=condition=Ready node/$(hostname) --timeout=5m
if ! command -v helm &> /dev/null; then
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
kubectl create namespace cert-manager || true
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.12.2/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=10m
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
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update
kubectl create namespace cattle-system || true
helm upgrade --install rancher rancher-latest/rancher \
  --namespace cattle-system\
  --set hostname=$DOMAIN \
  --set replicas=1 \
  --set ingress.tls.source=cert-manager \
  --set ingress.tls.certManagerIssuerName=letsencrypt-http \
  --set ingress.extraAnnotations."cert-manager\.io/cluster-issuer"=letsencrypt-http \
  --set ingress.tls.certmanager=true \
  --set privateCA=true
echo "### Esperando despliegue de Rancher..."
if kubectl -n cattle-system rollout status deploy/rancher --timeout=30m; then
  echo "✅ Rancher instalado correctamente. Accede a: https://$DOMAIN"
else
  echo "❌ ERROR: El despliegue de Rancher no fue exitoso dentro del tiempo esperado."
  exit 1
fi
sleep 60  # Esperar 1 minuto, puedes ajustar
CERT_STATUS=$(kubectl -n cattle-system get certificate tls-rancher-ingress --ignore-not-found -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
if [ "$CERT_STATUS" != "True" ]; then
  cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-rancher-ingress
  namespace: cattle-system
spec:
  secretName: tls-rancher-ingress
  duration: 2160h # 90 días
  renewBefore: 360h # Renovar 15 días antes
  issuerRef:
    name: letsencrypt-http
    kind: ClusterIssuer
  commonName: $DOMAIN
  dnsNames:
  - $DOMAIN
EOF
else
  echo "### El certificado tls-rancher-ingress ya existe y está listo."
fi
kubectl -n cattle-system wait --for=condition=Ready certificate/tls-rancher-ingress --timeout=30m || true