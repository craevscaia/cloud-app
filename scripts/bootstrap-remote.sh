#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="cloud-lab"
REGION="${DO_REGION:-fra1}"

cd "$(dirname "$0")/.."

command -v doctl >/dev/null || { echo "doctl not installed. https://docs.digitalocean.com/reference/doctl/how-to/install/"; exit 1; }
test -f .env.remote || { echo "Create .env.remote from .env.remote.example"; exit 1; }

echo ">>> 1/8 Ensuring DOKS cluster exists"
if ! doctl kubernetes cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  doctl kubernetes cluster create "$CLUSTER_NAME" \
    --region "$REGION" \
    --node-pool "name=default;size=s-2vcpu-4gb;count=2" \
    --wait
fi
doctl kubernetes cluster kubeconfig save "$CLUSTER_NAME"

echo ">>> 1b/8 Attaching DOCR registry credentials to cluster"
doctl kubernetes cluster registry add "$CLUSTER_NAME" >/dev/null 2>&1 || true
kubectl patch serviceaccount default -p '{"imagePullSecrets":[{"name":"registry-cloud-lab"}]}' || true

echo ">>> 2/8 Installing ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f charts/ingress-nginx/values.yaml \
  --set controller.metrics.serviceMonitor.enabled=false \
  --wait

echo ">>> 3/8 Waiting for LoadBalancer IP"
LB_IP=""
for i in {1..60}; do
  LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "$LB_IP" ]] && break
  sleep 5
done
[[ -n "$LB_IP" ]] || { echo "No LB IP after 5 min"; exit 1; }
echo "LB_IP=$LB_IP"
HOST="cloud-app.${LB_IP}.nip.io"

echo ">>> 4/8 Substituting ingress host"
cp k8s/remote/ingress-patch.yaml k8s/remote/ingress-patch.yaml.bak
sed -i.tmp "s/CLOUD_APP_HOST/${HOST}/g" k8s/remote/ingress-patch.yaml && rm -f k8s/remote/ingress-patch.yaml.tmp

echo ">>> 5/8 Installing kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f charts/kube-prometheus-stack/values.yaml \
  --set "grafana.ingress.hosts[0]=grafana.${LB_IP}.nip.io" \
  --wait

echo ">>> 5b/8 Re-enabling ingress-nginx ServiceMonitor (CRDs now present)"
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx \
  -f charts/ingress-nginx/values.yaml \
  --wait

echo ">>> 6/8 Installing loki-stack"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install loki grafana/loki-stack \
  -n monitoring \
  -f charts/loki-stack/values.yaml \
  --wait

echo ">>> 7/8 Applying k8s/remote overlay"
kubectl apply -k k8s/remote
kubectl rollout status deployment/cloud-app --timeout=300s

echo ">>> 8/8 Smoke test"
sleep 5
curl -sf "http://${HOST}/" && echo
curl -sf -X POST "http://${HOST}/messages" \
  -H 'Content-Type: application/json' \
  -d '{"text":"hello from cloud"}' && echo
curl -sf "http://${HOST}/messages" && echo

echo
echo "App URL:     http://${HOST}/"
echo "Grafana URL: http://grafana.${LB_IP}.nip.io/  (admin/admin)"
echo "Restore ingress file before next run: mv k8s/remote/ingress-patch.yaml.bak k8s/remote/ingress-patch.yaml"
