# Cloud Lab — Demo Runbook

One command per README requirement, executable against either the local (`kind`) or remote (`DOKS`) cluster.

Set `HOST` first:
- Local: `export HOST=localhost:28080` (the host port the kind ingress is mapped to — see `scripts/kind-config.yaml`)
- Remote: `export HOST=cloud-app.<LB-IP>.nip.io`

## Requirement 1 — Docker image
```bash
docker images | grep cloud-app
docker run --rm cloud-app:local java -version
```

## Requirement 2 — Published to registry
```bash
curl -sI https://ghcr.io/v2/infigo-adrian/cloud-app/manifests/latest | head
# Or: open https://github.com/craevscaia?tab=packages
```

## Requirement 3 — Deployed to K8s
```bash
kubectl get deploy,svc,ingress,hpa,statefulset
```

## Requirement 4 — K8s on cloud
```bash
doctl kubernetes cluster get cloud-lab
kubectl get nodes -o wide
```

## Requirement 5 — Internet-accessible
```bash
curl -i "http://${HOST}/"
```

## Requirement 6 — Scale
```bash
kubectl scale deployment/cloud-app --replicas=4
kubectl get pods -l app.kubernetes.io/name=cloud-app -w    # Ctrl+C when 4 are Ready
kubectl scale deployment/cloud-app --replicas=2
```

## Requirement 7 — Zero-downtime updates
In one terminal:
```bash
while true; do curl -s -o /dev/null -w "%{http_code}\n" "http://${HOST}/"; sleep 0.2; done
```
In another:
```bash
kubectl set image deployment/cloud-app cloud-app=ghcr.io/craevscaia/cloud-app:sha-<NEW>
kubectl rollout status deployment/cloud-app
```
Confirm the curl loop stays at 200 throughout.

## Requirement 8 — Rollback
```bash
kubectl rollout history deployment/cloud-app
kubectl rollout undo deployment/cloud-app
kubectl rollout status deployment/cloud-app
```

## Requirement 9 — Monitoring
```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# Open http://localhost:3000  (admin/admin), see "Cloud App" dashboard
```

## Requirement 10 — Autoscale
```bash
kubectl get hpa cloud-app
# Generate load:
kubectl run -it --rm load --image=busybox:1.36 --restart=Never -- \
  sh -c "while true; do wget -q -O- http://cloud-app:8080/messages; done"
# Watch:
kubectl get hpa cloud-app -w
```

## Requirement 11 — Centralized logging
In Grafana → Explore → Loki → query: `{app_kubernetes_io_name="cloud-app"}`
Or via CLI:
```bash
kubectl -n monitoring logs deploy/loki -c loki | tail
```

## Requirement 12 — Metrics export
```bash
kubectl port-forward svc/cloud-app 8080:8080
curl http://localhost:8080/actuator/prometheus | head
```

## Requirement 13 — Database in separate container
```bash
kubectl get pod -l app.kubernetes.io/name=postgres -o wide
kubectl exec -it postgres-0 -- psql -U cloudapp -d cloudapp -c "SELECT count(*) FROM messages;"
```

## Requirement 14 — Storage mounted to DB
```bash
kubectl get pvc
kubectl describe pvc data-postgres-0 | grep -E "StorageClass|Capacity|Used By"
# Persistence proof:
kubectl delete pod postgres-0
kubectl wait --for=condition=ready pod/postgres-0 --timeout=120s
kubectl exec postgres-0 -- psql -U cloudapp -d cloudapp -c "SELECT count(*) FROM messages;"
# Same count as before delete.
```

## Teardown (remote only)
```bash
bash scripts/teardown-remote.sh
```
