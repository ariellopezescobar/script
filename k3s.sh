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
curl -o letsencrypt-ca.pem https://letsencrypt.org/certs/isrgrootx1.pem.txt
cat letsencrypt-ca.pem | awk '{printf "%s\\n", $0}' > letsencrypt-ca-escaped.txt
CACERTS=$(cat letsencrypt-ca-escaped.txt)
helm upgrade --install rancher rancher-latest/rancher \
  --namespace cattle-system --create-namespace \
  --set hostname=$DOMAIN \
  --set replicas=1 \
  --set ingress.tls.source=cert-manager \
  --set ingress.tls.certManagerIssuerName=letsencrypt-http \
  --set ingress.tls.certmanager=true \
  --set ingress.extraAnnotations."cert-manager\.io/cluster-issuer"=letsencrypt-http \
  --set global.cacerts="$CACERTS"
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

DOMINIO="k3s.oruro.gob.bo"
ARCHIVO_CERT="/tmp/rancher-ca.crt"

echo "🔐 Extrayendo certificado de $DOMINIO:443 ..."
echo | openssl s_client -connect "$DOMINIO:443" -showcerts 2>/dev/null \
  | openssl x509 -outform PEM > "$ARCHIVO_CERT"

if [[ ! -s "$ARCHIVO_CERT" ]]; then
  echo "❌ No se pudo extraer el certificado de $DOMINIO"
  exit 1
fi

echo "✅ Certificado extraído correctamente."

echo "🔑 Eliminando el secret previo (si existe)..."
kubectl -n cattle-system delete secret tls-ca || true

echo "🔑 Creando el secret tls-ca con el certificado..."
kubectl -n cattle-system create secret generic tls-ca --from-file=cacerts.pem="$ARCHIVO_CERT"

echo "⚙️  Reconfigurando Rancher para usar el privateCA..."
helm upgrade rancher rancher-latest/rancher \
  --namespace cattle-system \
  --set hostname="$DOMINIO" \
  --set ingress.tls.source=secret \
  --set privateCA=true

echo "♻ Reiniciando Rancher para aplicar cambios..."
kubectl -n cattle-system rollout restart deployment rancher

echo "⏳ Espera 30 segundos a que Rancher reinicie..."
sleep 30

echo "🔍 Validando que Rancher publique correctamente el cacerts..."
curl -sk "https://$DOMINIO/cacerts" | openssl x509 -noout -fingerprint -sha256 || {
  echo "❌ Rancher aún no publica el cacerts correctamente"
  exit 1
}

echo "✅ Proceso finalizado. Puedes registrar nodos con el nuevo --ca-checksum."