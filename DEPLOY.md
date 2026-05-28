# Live Deployment — Cloud Lab

Provisioned 2026-05-28 to DigitalOcean Kubernetes (DOKS).

## Access

| Resource | URL / how-to | Auth |
|---|---|---|
| **App** (public) | http://cloud-app.129.212.140.160.nip.io/ | none |
| **App health** | http://cloud-app.129.212.140.160.nip.io/actuator/health | none |
| **Messages API** | `POST /messages {"text":"..."}` then `GET /messages` | none |
| **Grafana** | `kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80` → http://localhost:3000 | admin / admin |
| **Prometheus** | `kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090` | none |
| **Loki** (via Grafana → Explore → Loki) | query `{app="cloud-app"}` | — |

## Cluster facts

| Item | Value |
|---|---|
| Cloud provider | DigitalOcean |
| Cluster name | `cloud-lab` |
| Region | `fra1` |
| Nodes | 2 × `s-2vcpu-4gb` |
| Kubernetes version | 1.36.0-do.0 |
| LoadBalancer IP | `129.212.140.160` |
| Container registry | `registry.digitalocean.com/cloud-lab/cloud-app:latest` |

## Requirement verification

| # | Requirement | Status | Evidence |
|---|---|---|---|
| 1 | Docker image | ✅ | `docker/Dockerfile`, image pushed to DOCR |
| 2 | Published to registry | ✅ | `registry.digitalocean.com/cloud-lab/cloud-app:latest` |
| 3 | Deployed to K8s | ✅ | `kubectl get deploy,svc,ingress,hpa,statefulset` — all Ready |
| 4 | K8s on cloud provider | ✅ | DOKS, fra1, 2 nodes |
| 5 | Internet-accessible | ✅ | `curl http://cloud-app.129.212.140.160.nip.io/` → 200 |
| 6 | Scalable | ✅ | `kubectl scale deploy/cloud-app --replicas=N` |
| 7 | Zero-downtime updates | ✅ | RollingUpdate (maxSurge:1, maxUnavailable:0) + readiness probe |
| 8 | Rollback | ✅ | `revisionHistoryLimit: 10` → `kubectl rollout undo` |
| 9 | Monitoring | ✅ | kube-prometheus-stack installed; Grafana shows app dashboard |
| 10 | Autoscale | ✅ | HPA `cloud-app` (2–6 pods, CPU 70% / Mem 80%); metrics-server installed |
| 11 | Centralised logs | ✅ | Loki + Promtail collecting; query `{app="cloud-app"}` returns lines |
| 12 | Metrics export | ✅ | `/actuator/prometheus`; Prometheus has 2 cloud-app targets `up` |
| 13 | DB in separate container | ✅ | `statefulset/postgres` (postgres:16-alpine) |
| 14 | Storage mounted to DB | ✅ | PVC `data-postgres-0` 2Gi on `do-block-storage` |

## Teardown (when done)

```bash
bash scripts/teardown-remote.sh
# Also delete the registry to stop charges:
doctl registry delete --force
```

## Notes on changes made during deploy

- `k8s/remote/deployment-patch.yaml` — image switched from `ghcr.io/craevscaia/cloud-app` to `registry.digitalocean.com/cloud-lab/cloud-app` (GHCR token lacked `write:packages`; DOCR was free and we already had the DO token).
- `scripts/bootstrap-remote.sh` — added two steps:
  1. `doctl kubernetes cluster registry add` + patch default ServiceAccount with imagePullSecret (so pods can pull from DOCR).
  2. Install ingress-nginx without ServiceMonitor first; re-enable after kube-prometheus-stack installs the CRDs.
- `metrics-server` installed separately (`kubectl apply -f .../components.yaml`) — DOKS does not ship it by default, and HPA needs it.
- `.env.remote` generated with a random 32-char password and copied into `k8s/remote/` where kustomize's secretGenerator expects it.
