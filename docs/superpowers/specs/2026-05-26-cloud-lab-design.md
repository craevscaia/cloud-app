# Cloud Lab Design — Spring Boot on Kubernetes (local + DigitalOcean)

**Date:** 2026-05-26
**Status:** Draft, awaiting user review
**Lab requirements:** see `README.md` (14 items)

## 1. Goal

Take the existing Spring Boot "Hello World" app and ship the full cloud lab: containerized, published to a registry, deployed to Kubernetes both locally (`kind`) and on a real cloud (DigitalOcean Kubernetes / DOKS), with rolling updates, rollback, HPA, centralized logging, metrics, and a separate Postgres container with persistent storage.

Same manifests run locally and remotely — only an overlay differs.

## 2. Non-goals

- HTTPS / cert-manager. README does not require it. The internet-accessible URL is plain HTTP via `nip.io`.
- GitOps (ArgoCD, Flux). Manual `kubectl apply -k` per environment.
- ORM / JPA. The lab is about infra, not data modeling. `JdbcTemplate` is enough for one small table.
- Multi-tenant / production hardening (NetworkPolicies, PodSecurityPolicy, secret encryption at rest).

## 3. Architecture

```
Internet ──▶ ingress-nginx ──▶ Service: cloud-app ──▶ Deployment: cloud-app
              (LoadBalancer on DO,                     (2-N replicas, HPA)
               port-map on kind)                             │
                                                             ▼
                                          Service: postgres ──▶ StatefulSet (1 replica)
                                                                + PVC

Observability namespace (`monitoring`):
  • kube-prometheus-stack — Prometheus, Grafana, node-exporter, kube-state-metrics
  • loki + promtail — promtail tails all pod stdout, ships to Loki
  • Grafana — preloaded dashboards for app metrics and logs
```

## 4. Repository layout

```
/
├── src/...                          # Spring Boot app (extended)
├── docker/
│   └── Dockerfile                   # multi-stage, non-root, JRE 17
├── k8s/
│   ├── base/                        # shared manifests
│   ├── local/                       # kind overlay (kustomization.yaml + patches)
│   └── remote/                      # DOKS overlay
├── charts/                          # third-party Helm values, pinned
│   ├── ingress-nginx/values.yaml
│   ├── kube-prometheus-stack/values.yaml
│   └── loki-stack/values.yaml
├── scripts/
│   ├── bootstrap-local.sh           # kind create cluster + helm installs + apply overlay
│   └── bootstrap-remote.sh          # doctl create DOKS + helm installs + apply overlay
├── .github/workflows/
│   └── build-and-push.yml           # build JAR → image → ghcr.io
└── docs/
    └── demo-runbook.md              # one command per requirement, for grading
```

## 5. Application changes

### 5.1 New dependencies (`build.gradle.kts`)

```kotlin
implementation("org.springframework.boot:spring-boot-starter-actuator")
implementation("org.springframework.boot:spring-boot-starter-jdbc")
implementation("io.micrometer:micrometer-registry-prometheus")
implementation("org.flywaydb:flyway-core")
implementation("org.postgresql:postgresql")
implementation("net.logstash.logback:logstash-logback-encoder:7.4")
testImplementation("com.h2database:h2")
```

### 5.2 New files

| File | Purpose |
|---|---|
| `src/main/kotlin/md/utm/cloudapp/messages/Message.kt` | `data class Message(val id: Long?, val text: String, val createdAt: Instant?)` |
| `src/main/kotlin/md/utm/cloudapp/messages/MessageRepository.kt` | `JdbcTemplate`-backed; `findAll()`, `insert(text)` |
| `src/main/kotlin/md/utm/cloudapp/messages/MessagesController.kt` | `GET /messages` → list, `POST /messages` `{text}` → inserted row |
| `src/main/resources/db/migration/V1__messages.sql` | `CREATE TABLE messages (id BIGSERIAL PRIMARY KEY, text TEXT NOT NULL, created_at TIMESTAMPTZ NOT NULL DEFAULT now())` |
| `src/main/resources/logback-spring.xml` | Console appender for `local` profile, JSON (`LogstashEncoder`) otherwise |
| `src/test/kotlin/md/utm/cloudapp/messages/MessagesControllerIT.kt` | `@SpringBootTest`, H2 in `test` profile, POST then GET round-trip |

### 5.3 `application.properties` additions

```properties
spring.datasource.url=${SPRING_DATASOURCE_URL}
spring.datasource.username=${SPRING_DATASOURCE_USERNAME}
spring.datasource.password=${SPRING_DATASOURCE_PASSWORD}
management.endpoints.web.exposure.include=health,info,prometheus
management.endpoint.health.probes.enabled=true
management.health.livenessstate.enabled=true
management.health.readinessstate.enabled=true
```

`management.health.readinessstate.enabled=true` flips the `/actuator/health/readiness` endpoint based on DB + Flyway state — exactly what K8s readiness probes need for zero-downtime rollouts.

## 6. Dockerfile

```dockerfile
FROM eclipse-temurin:17-jdk-alpine AS build
WORKDIR /app
COPY gradlew settings.gradle.kts build.gradle.kts ./
COPY gradle ./gradle
COPY src ./src
RUN ./gradlew bootJar --no-daemon

FROM eclipse-temurin:17-jre-alpine
RUN addgroup -S app && adduser -S app -G app
USER app
COPY --from=build /app/build/libs/*.jar /app/app.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","/app/app.jar"]
```

## 7. Kubernetes manifests (`k8s/base/`)

| File | Key fields |
|---|---|
| `deployment.yaml` | `replicas: 2`; `strategy: RollingUpdate {maxSurge: 1, maxUnavailable: 0}`; `revisionHistoryLimit: 10`; resources req 256Mi/250m, limit 512Mi/500m; env from `cloud-app-config` ConfigMap + `cloud-app-secret`; liveness `/actuator/health/liveness`, readiness `/actuator/health/readiness`; image `ghcr.io/infigo-adrian/cloud-app:latest` |
| `service.yaml` | ClusterIP, port 8080 |
| `ingress.yaml` | `ingressClassName: nginx`, host placeholder (overlays override) |
| `hpa.yaml` | min 2, max 6, CPU target 70%, memory target 80% |
| `configmap.yaml` | `SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/cloudapp` |
| `secret.yaml` | Stub; real values from overlay `secretGenerator` |
| `postgres-statefulset.yaml` | `postgres:16-alpine`, 1 replica, `volumeClaimTemplate` 2Gi, creds from same Secret, readiness probe `pg_isready -U $POSTGRES_USER` |
| `postgres-service.yaml` | Headless `ClusterIP: None`, port 5432 |
| `servicemonitor.yaml` | Tells Prometheus to scrape `/actuator/prometheus` on the app Service |
| `kustomization.yaml` | Resource list + common labels (`app.kubernetes.io/name=cloud-app`, `app.kubernetes.io/part-of=cloud-lab`) |

### 7.1 Overlay: `k8s/local/`

- Image tag → `:local` (loaded into kind via `kind load docker-image cloud-app:local`)
- Ingress host → `localhost`
- Resources lowered (req 128Mi/100m) so it fits a laptop
- Storage class → `standard` (kind default)
- `secretGenerator` with literal DB credentials (lab-only, fine to commit a dev password)

### 7.2 Overlay: `k8s/remote/`

- Image tag → `:latest` or `:sha-<commit>` for traceability
- Ingress host → `cloud-app.<LB-IP>.nip.io` (substituted by `bootstrap-remote.sh` after the LB is provisioned)
- Storage class → `do-block-storage`
- LoadBalancer annotation: `service.beta.kubernetes.io/do-loadbalancer-name: cloud-lab-lb`
- `secretGenerator` reads from `.env.remote` (gitignored)

## 8. Observability stack

Both stacks installed in namespace `monitoring` by the bootstrap scripts.

- **kube-prometheus-stack** (Helm): Prometheus + Grafana + node-exporter + kube-state-metrics. Grafana admin password set via Helm values. App metrics arrive via the `ServiceMonitor` shipped in `k8s/base/`.
- **loki-stack** (Helm) with promtail enabled: promtail scrapes all pods' stdout. JSON logs from the app are parsed into labelled fields in Loki.
- **Grafana access:** second Ingress at `grafana.<host>` (locally `localhost/grafana` via path-based routing, or use `kubectl port-forward` if path routing gets fiddly).
- **Dashboards:** two ConfigMaps in `k8s/base/grafana-dashboards/` with label `grafana_dashboard: "1"`, auto-loaded by Grafana's sidecar — (a) JVM + HTTP request metrics, (b) Loki log panel filtered to `app=cloud-app`.

## 9. CI — GitHub Actions

`.github/workflows/build-and-push.yml` on push to `main` and PRs:

1. Checkout
2. Set up JDK 17
3. `./gradlew test bootJar`
4. `docker/login-action` to `ghcr.io` using `GITHUB_TOKEN`
5. `docker/build-push-action` builds + tags + pushes:
   - `ghcr.io/infigo-adrian/cloud-app:latest`
   - `ghcr.io/infigo-adrian/cloud-app:sha-<commit>`

Image must be made **public** in GHCR settings so DOKS can pull without an `imagePullSecret`.

## 10. Bootstrap scripts

### 10.1 `scripts/bootstrap-local.sh`

```
1. kind create cluster --config kind-config.yaml         # extraPortMappings 80→80, 443→443
2. helm install ingress-nginx ingress-nginx/...
3. helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f charts/kube-prometheus-stack/values.yaml
4. helm install loki grafana/loki-stack -n monitoring -f charts/loki-stack/values.yaml
5. docker build -t cloud-app:local -f docker/Dockerfile .
6. kind load docker-image cloud-app:local
7. kubectl apply -k k8s/local
8. kubectl rollout status deployment/cloud-app
9. Smoke test: curl localhost/, curl -XPOST localhost/messages -d '{"text":"hi"}', curl localhost/messages
```

### 10.2 `scripts/bootstrap-remote.sh`

```
1. doctl kubernetes cluster create cloud-lab --node-pool "name=default;size=s-2vcpu-4gb;count=2"
2. doctl kubernetes cluster kubeconfig save cloud-lab
3. helm install ingress-nginx ...                        # DO auto-creates an LB
4. Wait for svc/ingress-nginx-controller external IP; substitute into k8s/remote/ingress.yaml host
5. helm install monitoring + loki                        # same as local
6. kubectl apply -k k8s/remote                           # image pulls from GHCR
7. kubectl rollout status deployment/cloud-app
8. Smoke test against http://cloud-app.<IP>.nip.io
```

## 11. Probe semantics

- **Liveness** = pod process is alive. Restart on failure. `initialDelaySeconds: 30`, `periodSeconds: 10`.
- **Readiness** = pod can serve. Cut from Service on failure (no restart). `initialDelaySeconds: 10`, `periodSeconds: 5`.

Spring Boot 3's readiness state flips to `OUT_OF_SERVICE` while Flyway is migrating or the DataSource is down, and to `ACCEPTING_TRAFFIC` once the app is live. This gives true zero-downtime rolling updates.

## 12. Requirement traceability

| # | Requirement | Where satisfied |
|---|---|---|
| 1 | Docker image | `docker/Dockerfile` |
| 2 | Published to registry | GitHub Actions → `ghcr.io/infigo-adrian/cloud-app` |
| 3 | Deployed to K8s | `k8s/base/deployment.yaml` + overlays |
| 4 | K8s on cloud | DOKS via `scripts/bootstrap-remote.sh` |
| 5 | Internet-accessible | ingress-nginx + DO LB + nip.io host |
| 6 | Scale | `kubectl scale deployment/cloud-app --replicas=N` + HPA |
| 7 | Zero-downtime updates | `RollingUpdate maxUnavailable: 0` + readiness probe |
| 8 | Rollback | `kubectl rollout undo deployment/cloud-app` (history kept) |
| 9 | Monitoring | Prometheus + Grafana dashboards |
| 10 | Autoscale | HPA on CPU 70% + memory 80%, min 2 max 6 |
| 11 | Centralized logging | Loki + promtail, JSON logs from `logstash-logback-encoder` |
| 12 | Metrics export | Actuator `/actuator/prometheus` scraped via ServiceMonitor |
| 13 | DB separate container | `postgres-statefulset.yaml` |
| 14 | Storage mounted to DB | `volumeClaimTemplate` 2Gi (`standard` locally, `do-block-storage` remote) |

## 13. Testing

1. **Unit/integration tests** — `MessagesControllerIT` boots the Spring context against H2 in profile `test`, exercises the round-trip. Runs in CI on every push.
2. **Local smoke test** — `bootstrap-local.sh` ends by `curl`ing the ingress and checking `kubectl rollout status`. Failures abort the script with a non-zero exit.
3. **Demo runbook** — `docs/demo-runbook.md` lists a one-line command per lab requirement for the grader (or for re-verification before submission).

## 14. Risks / open items

- **Image pull on DOKS:** GHCR image must be set public after the first push, or we add an `imagePullSecret`. Default plan: public image.
- **Grafana ingress path routing:** path-based routing with sub-paths can be fiddly with kube-prometheus-stack's default config. If it breaks, fall back to `kubectl port-forward` documented in the runbook — still satisfies requirement #9 (monitoring exists, accessible).
- **Cost on DigitalOcean:** 2× `s-2vcpu-4gb` nodes (~$24/mo) + LB (~$12/mo) ≈ $36/mo. Suggest tearing down the cluster (`doctl kubernetes cluster delete cloud-lab`) after the demo. Runbook documents this.
- **Database password rotation / encryption:** out of scope. Lab credentials are dev-only.
