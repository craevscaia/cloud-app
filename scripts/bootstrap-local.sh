#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="cloud-lab"
IMAGE_TAG="cloud-app:local"

cd "$(dirname "$0")/.."

echo ">>> 1/8 Ensuring kind cluster exists"
if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  kind create cluster --name "$CLUSTER_NAME" --config scripts/kind-config.yaml
fi
kubectl config use-context "kind-$CLUSTER_NAME"

echo ">>> 2/8 Installing kube-prometheus-stack (provides ServiceMonitor CRD)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f charts/kube-prometheus-stack/values.yaml \
  --wait

echo ">>> 3/8 Installing ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  -f charts/ingress-nginx/values.yaml \
  --set controller.service.type=NodePort \
  --set controller.hostPort.enabled=true \
  --set-string "controller.nodeSelector.ingress-ready=true" \
  --set "controller.tolerations[0].key=node-role.kubernetes.io/control-plane" \
  --set "controller.tolerations[0].operator=Equal" \
  --set "controller.tolerations[0].effect=NoSchedule" \
  --wait

echo ">>> 4/8 Installing loki-stack"
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install loki grafana/loki-stack \
  -n monitoring \
  -f charts/loki-stack/values.yaml \
  --wait

echo ">>> 5/8 Building app image"
docker build -t "$IMAGE_TAG" -f docker/Dockerfile .

echo ">>> 6/8 Loading image into kind"
kind load docker-image "$IMAGE_TAG" --name "$CLUSTER_NAME"

echo ">>> 7/8 Applying k8s/local overlay"
kubectl apply -k k8s/local
kubectl rollout status deployment/cloud-app --timeout=180s

echo ">>> 8/8 Smoke test"
sleep 5
curl -sf http://localhost:28080/ && echo
curl -sf -X POST http://localhost:28080/messages \
  -H 'Content-Type: application/json' \
  -d '{"text":"hello from bootstrap"}' && echo
curl -sf http://localhost:28080/messages && echo

echo
echo "Done."
echo "Grafana: kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80  (admin/admin)"
