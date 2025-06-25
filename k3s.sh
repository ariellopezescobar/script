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

ARCHIVO_CERT="cacerts.pem"
ARCHIVO_B64="cacerts.b64"
ARCHIVO_YAML="cacerts.yaml"

echo "### Paso 1: Descargando certificado desde $DOMAIN..."
echo | openssl s_client -connect "$DOMINIO:443" -servername "$DOMAIN" -showcerts 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > "$ARCHIVO_CERT"

echo "### Paso 2: Codificando certificado en base64 (una sola línea)..."
base64 -w0 "$ARCHIVO_CERT" > "$ARCHIVO_B64"

echo "### Paso 3: Generando archivo YAML..."
cat <<EOF > "$ARCHIVO_YAML"
apiVersion: management.cattle.io/v3
kind: Setting
metadata:
  name: cacerts
value: $(cat "$ARCHIVO_B64")
EOF

echo "### Paso 4: Aplicando con kubectl..."
kubectl apply -f "$ARCHIVO_YAML"

echo "### Certificado cargado correctamente."
echo "✔ Puedes verificar con:"
echo "kubectl get setting.management.cattle.io/cacerts -o jsonpath='{.value}' | base64 -d | openssl x509 -noout -fingerprint -sha256"
