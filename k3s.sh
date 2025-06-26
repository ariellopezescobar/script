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
#!/bin/bash
set -e

#!/bin/bash

set -e

DOMINIO="k3s.oruro.gob.bo"
ARCHIVO_CACERTS="/tmp/cacerts.yaml"
CERTS_EXTRAIDOS="/tmp/cert_chain.pem"

echo "🔐 Extrayendo certificados de $DOMINIO:443 ..."
openssl s_client -showcerts -connect "$DOMINIO:443" </dev/null 2>/dev/null | \
  awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/ { print }' > "$CERTS_EXTRAIDOS"

if [[ ! -s "$CERTS_EXTRAIDOS" ]]; then
  echo "❌ No se pudieron extraer certificados de $DOMINIO"
  exit 1
fi

echo "✅ Certificados extraídos: $(grep -c 'BEGIN CERTIFICATE' $CERTS_EXTRAIDOS)"

# Formatear el YAML
echo "📝 Generando archivo cacerts.yaml en $ARCHIVO_CACERTS ..."
{
  echo "apiVersion: management.cattle.io/v3"
  echo "kind: Setting"
  echo "metadata:"
  echo "  name: cacerts"
  echo "value: |"
  sed 's/^/  /' "$CERTS_EXTRAIDOS"
} > "$ARCHIVO_CACERTS"

echo "🚀 Aplicando cacerts.yaml a Rancher..."
kubectl apply -f "$ARCHIVO_CACERTS"

echo "🔍 Verificando que Rancher lo haya recibido..."
kubectl get setting.cattle.io cacerts -o yaml | grep -A 5 '^value:' || true

echo "✅ Todo listo. Puedes registrar nodos usando --ca-checksum ahora."
