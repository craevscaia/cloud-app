# Study Guide — Cloud Lab Defense

A plain-language walkthrough of what this lab does, why each piece exists, what to say when defending it, and questions the examiner is likely to ask.

---

## 1. The 30-second elevator pitch

> "I built a Spring Boot web app, packaged it as a Docker image, published it to a container registry, and deployed it to a Kubernetes cluster — both locally with kind and on DigitalOcean's managed Kubernetes (DOKS). The cluster runs two replicas of the app behind an Ingress with autoscaling, talks to a Postgres database in a separate container with persistent storage, and is monitored by Prometheus and Grafana with centralized logs going to Loki. Updates are rolling and zero-downtime, and the deployment can be rolled back with one command."

Memorize that. Everything else is detail.

---

## 2. The architecture in one picture

```
                            Internet
                                │
                                ▼
                  ┌─────────────────────────────┐
                  │   Load Balancer (DO)        │
                  │   or hostPort (kind, local) │
                  └─────────────┬───────────────┘
                                │
                                ▼
                  ┌─────────────────────────────┐
                  │   ingress-nginx pod         │
                  │   (routes by Host header)   │
                  └─────────────┬───────────────┘
                                │
                                ▼
              ┌────────────────────────────────────┐
              │  Service: cloud-app (ClusterIP)    │
              └────────┬──────────────────┬────────┘
                       │                  │
                       ▼                  ▼
              ┌─────────────┐    ┌─────────────┐
              │ cloud-app   │    │ cloud-app   │  ← 2 to 6 replicas (HPA)
              │ pod #1      │    │ pod #2      │     same image, same code
              └──────┬──────┘    └──────┬──────┘
                     │                  │
                     └─────────┬────────┘
                               │
                               ▼
                     ┌──────────────────┐
                     │ Service: postgres│
                     └────────┬─────────┘
                              │
                              ▼
                     ┌──────────────────┐
                     │ postgres-0 pod   │
                     │ (StatefulSet)    │
                     │   ↓ mounted ↓    │
                     │ PVC: 2Gi disk    │
                     └──────────────────┘

   Side-cluster (namespace: monitoring):
   • Prometheus  ← scrapes /actuator/prometheus from cloud-app every 15s
   • Grafana     ← shows dashboards, queries Prometheus + Loki
   • Loki        ← stores logs
   • promtail    ← runs on every node, ships pod stdout to Loki
```

If the examiner asks "explain the architecture" — draw this diagram on paper. It's the answer to half the possible questions.

---

## 3. Each requirement — what, why, where, what to say

### Requirement 1 — Application as a Docker image

**What:** The Spring Boot app is built into a Docker image using a multi-stage Dockerfile.

**Why multi-stage:** First stage uses a JDK image (big, ~400MB) to compile and build the JAR. Second stage uses a JRE image (smaller, ~200MB) and copies only the JAR. The final image is small, doesn't ship the compiler or source code, and runs as a non-root user.

**Where:** `docker/Dockerfile`

**What to say:** "I use a multi-stage build so the final image only contains the JRE and the JAR — not the JDK or build tools. It also runs as a non-root user, which is a security best practice."

**Demo:**
```bash
docker images | grep cloud-app
docker history cloud-app:local            # show layers, multi-stage
```

---

### Requirement 2 — Published to a Docker registry

**What:** A GitHub Actions workflow builds the image on every push to `main` and pushes it to GitHub Container Registry (GHCR).

**Why GHCR:** Free, integrated with the GitHub account, no separate credentials. Both kind and DOKS can pull from it without extra setup once the package is made public.

**Where:** `.github/workflows/build-and-push.yml`

**What to say:** "GHCR is GitHub's container registry — free for public images. The workflow uses `GITHUB_TOKEN` so I don't need to manage a separate password. Each push gets two tags: `:latest` and `:sha-<commit>`, so I can always pin a deployment to a specific commit."

**Demo:**
```bash
cat .github/workflows/build-and-push.yml | head -30
# Open https://github.com/craevscaia?tab=packages
```

---

### Requirement 3 — Deployed to a Kubernetes cluster

**What:** Kubernetes manifests describe a `Deployment` (the app), a `Service` (network endpoint), an `Ingress` (HTTP routing), a `ConfigMap`/`Secret` (config), and a `StatefulSet` for the database.

**Why a Deployment and not a Pod:** A Pod is one instance; a Deployment manages a set of identical Pods and handles updates, scaling, and self-healing. If a pod crashes, the Deployment recreates it.

**Where:** `k8s/base/deployment.yaml`, `service.yaml`, `ingress.yaml`, plus the overlays in `k8s/local/` and `k8s/remote/`.

**What to say:** "I use Kustomize to keep the same base manifests for both environments. The local overlay tweaks the image tag and resource requests for my laptop; the remote overlay points at the GHCR image and uses DigitalOcean block storage. `kubectl apply -k k8s/local` and `kubectl apply -k k8s/remote` — same base, different overlay."

**Demo:**
```bash
kubectl get deploy,svc,ingress,statefulset,hpa
kubectl kustomize k8s/local | head -30   # show the rendered manifest
```

---

### Requirement 4 — Kubernetes on a cloud provider

**What:** DigitalOcean Kubernetes Service (DOKS) provides a managed Kubernetes control plane. The `bootstrap-remote.sh` script uses `doctl` to create the cluster.

**Why DOKS:** It's the cheapest managed Kubernetes (~$24/mo for 2 nodes). AWS EKS costs $73/month just for the control plane, before nodes. DOKS gives free control plane and only charges for worker nodes.

**Where:** `scripts/bootstrap-remote.sh`

**What to say:** "DigitalOcean handles the Kubernetes control plane — etcd, API server, scheduler. I just declare the worker nodes I want. The script provisions everything in one command."

**Demo (theoretical — without actually running it):**
```bash
cat scripts/bootstrap-remote.sh
# Walk through the 8 steps the script runs
```

---

### Requirement 5 — Accessible from the internet

**What:** ingress-nginx on DOKS provisions a DigitalOcean Load Balancer with a public IP. We use `nip.io` for a free hostname.

**Why nip.io:** A wildcard DNS service — `1.2.3.4.nip.io` resolves to `1.2.3.4` automatically. No DNS records to register, no domain to buy.

**Where:** `k8s/remote/ingress-patch.yaml` (host gets substituted at deploy time)

**What to say:** "Once ingress-nginx is installed, DigitalOcean automatically provisions a Load Balancer with a public IP. nip.io gives me a hostname for free — `cloud-app.<IP>.nip.io` resolves to the LB IP. Any browser can reach it."

**Demo:**
```bash
# Local (kind):
curl -i http://localhost:28080/
# Remote (when deployed):
# curl -i http://cloud-app.<LB-IP>.nip.io/
```

---

### Requirement 6 — Scale the application

**What:** Two ways — manual scale (`kubectl scale`) and automatic via HPA.

**Why both:** Manual scaling is for predictable load (e.g., I know Black Friday is coming, scale up to 10). HPA is for unpredictable load (CPU spike at 3 AM, scale up automatically).

**Where:** `k8s/base/hpa.yaml`

**What to say:** "The Deployment has `replicas: 2`. I can override that with `kubectl scale deployment/cloud-app --replicas=5` — Kubernetes creates three more pods. The HPA does this automatically based on CPU and memory usage."

**Demo:**
```bash
kubectl scale deployment/cloud-app --replicas=4
kubectl get pods -l app.kubernetes.io/name=cloud-app -w   # Ctrl+C when 4 are Ready
kubectl scale deployment/cloud-app --replicas=2
```

---

### Requirement 7 — Update without downtime

**What:** The Deployment uses `RollingUpdate` strategy: `maxSurge: 1, maxUnavailable: 0`. Kubernetes brings up a new pod first, waits for it to be Ready, then kills an old one.

**Why `maxUnavailable: 0`:** Guarantees we never drop below the desired replica count. Combined with `replicas: 2`, this means we always have at least 2 healthy pods. (`maxSurge: 1` means at most 3 pods total exist during rollout — one extra, one old, two new at peak.)

**Why readiness probes matter:** Kubernetes considers a pod "Ready" only when the readiness probe passes. We hit `/actuator/health/readiness`, which returns 200 only after Flyway has migrated the schema and the DataSource is healthy. So traffic only goes to pods that can actually serve.

**Where:** `k8s/base/deployment.yaml` (lines: `strategy:` block + `readinessProbe:`)

**What to say:** "Spring Boot Actuator exposes a `/actuator/health/readiness` endpoint that flips to UP only when the application can actually serve traffic — Flyway done, DataSource healthy. Kubernetes polls that endpoint and only sends traffic to pods that pass. Combined with `maxUnavailable: 0`, the rolling update is truly zero-downtime."

**Demo:**
```bash
# In terminal 1:
while true; do curl -s -o /dev/null -w "%{http_code}\n" http://localhost:28080/; sleep 0.2; done
# In terminal 2:
kubectl rollout restart deployment/cloud-app
kubectl rollout status deployment/cloud-app
# Terminal 1 should never show anything but 200.
```

(We verified this — 80/80 requests returned 200 during a real rollout.)

---

### Requirement 8 — Rollback to a previous version

**What:** Kubernetes keeps a history of revisions (`revisionHistoryLimit: 10` in our case). `kubectl rollout undo` rolls back to the previous one.

**Why this works:** Every time you `kubectl apply` a change to the Deployment, Kubernetes saves the old ReplicaSet definition. To roll back, it scales the old ReplicaSet up and the new one down — the same rolling strategy as forward updates.

**Where:** `k8s/base/deployment.yaml` (the `revisionHistoryLimit: 10` field)

**What to say:** "Kubernetes stores the last 10 revisions of the Deployment. `kubectl rollout undo` is just a rolling update in reverse — same zero-downtime guarantees. I can also roll back to a specific revision with `--to-revision=N`."

**Demo:**
```bash
kubectl rollout history deployment/cloud-app
kubectl rollout undo deployment/cloud-app
kubectl rollout status deployment/cloud-app
```

---

### Requirement 9 — Monitor the application

**What:** Prometheus scrapes metrics from the app every 15 seconds; Grafana shows dashboards.

**Why this stack:** Prometheus + Grafana is the de facto standard for Kubernetes monitoring. We install them with the `kube-prometheus-stack` Helm chart — it bundles Prometheus, Grafana, node-exporter (node metrics like CPU/disk), and kube-state-metrics (cluster object metrics like pod counts).

**How the app exposes metrics:** Spring Boot Actuator + Micrometer Prometheus registry. Adding the `micrometer-registry-prometheus` dependency makes `/actuator/prometheus` available; it returns metrics in Prometheus's text format (JVM heap, GC, HTTP request latency, Hikari connection pool, etc.).

**How Prometheus knows to scrape it:** A `ServiceMonitor` resource (`k8s/base/servicemonitor.yaml`) tells Prometheus: "Look for Services with label `app.kubernetes.io/name=cloud-app` and scrape their `http` port at path `/actuator/prometheus`." The `release: monitoring` label on the ServiceMonitor matches Prometheus's selector.

**Where:** `k8s/base/servicemonitor.yaml`, `charts/kube-prometheus-stack/values.yaml`, dashboards in `k8s/base/grafana-dashboards/`.

**What to say:** "Prometheus is a pull-based monitoring system — it scrapes metrics endpoints on a schedule. Spring Boot exposes the endpoint via Actuator. I tell Prometheus what to scrape using a ServiceMonitor, which is a CRD from the Prometheus Operator. Grafana queries Prometheus and renders dashboards — I ship two as ConfigMaps that Grafana's sidecar auto-loads."

**Demo:**
```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# Open http://localhost:3000  — admin/admin
# Show the "Cloud App" dashboard with HTTP requests/sec and JVM heap
```

---

### Requirement 10 — Autoscale based on load

**What:** HPA (HorizontalPodAutoscaler) watches CPU and memory usage. When average CPU > 70% or memory > 80%, it adds pods. When usage drops, it removes pods. Bounds: min 2, max 6.

**Why CPU + memory:** CPU spikes when the app is doing real work (parsing JSON, hitting the DB). Memory spikes when there are leaks or a flood of long-lived requests. Either is a signal to scale.

**Why min 2:** Single-pod deployments fail completely if the one pod crashes. With min 2, we always have redundancy and zero-downtime updates work properly.

**Where:** `k8s/base/hpa.yaml`

**What to say:** "The HPA queries the metrics-server (or kube-prometheus-stack's metrics adapter) for CPU and memory averages across all pods. If the average CPU goes above 70%, it adds pods until it's back below. The min of 2 guarantees redundancy."

**Demo:**
```bash
kubectl get hpa cloud-app
# Generate load:
kubectl run -it --rm load --image=busybox:1.36 --restart=Never -- \
  sh -c "while true; do wget -q -O- http://cloud-app:8080/messages; done"
# In another terminal:
kubectl get hpa cloud-app -w
# Watch REPLICAS climb from 2 to 3, 4, ...
```

---

### Requirement 11 — Centralized logging

**What:** Logs go to stdout in JSON format. Promtail (a small agent running on every node) tails the container logs and ships them to Loki. Grafana queries Loki to display them.

**Why JSON logs:** Loki parses the JSON fields into labels — so you can filter logs by `level=ERROR`, `logger=md.utm.cloudapp.messages.MessagesController`, etc. Without structured logging, you'd be grep-ing free text.

**Why stdout and not files:** Kubernetes convention. The container runtime captures stdout/stderr and exposes it via `kubectl logs`. Promtail reads from the same source.

**Where:** `src/main/resources/logback-spring.xml` (the `LogstashEncoder` part), `charts/loki-stack/values.yaml`

**What to say:** "I use `logstash-logback-encoder` to emit logs as JSON to stdout. promtail is a DaemonSet — one pod per node — that tails every container's stdout and ships it to Loki. Loki indexes the metadata (pod name, namespace, labels) but stores the log content cheaply, similar to Prometheus's model. Grafana queries it via LogQL."

**Demo:**
```bash
# In Grafana: Explore → Loki → query: {app_kubernetes_io_name="cloud-app"}
# Or via CLI:
kubectl logs deploy/cloud-app --tail=5
# Show JSON output, then explain promtail/Loki path
```

---

### Requirement 12 — Application metrics to a monitoring system

**What:** Same mechanism as #9 from the app's side. Adding `micrometer-registry-prometheus` to `build.gradle.kts` and exposing it via `management.endpoints.web.exposure.include=prometheus` is all the app needs to do.

**Where:** `build.gradle.kts`, `src/main/resources/application.properties`

**What to say:** "Micrometer is Spring's metrics abstraction — like SLF4J but for metrics. The Prometheus registry exposes the same metrics in Prometheus's exposition format at `/actuator/prometheus`. The HTTP request metrics, GC counts, Hikari connection pool stats, and any custom metrics I add all show up automatically."

**Demo:**
```bash
kubectl port-forward svc/cloud-app 8080:8080
curl http://localhost:8080/actuator/prometheus | head -20
```

---

### Requirement 13 — Database in a separate container

**What:** Postgres 16 runs as its own `StatefulSet` with one replica, in a separate pod from the app. The app finds it via the `postgres` Service.

**Why StatefulSet and not Deployment:** StatefulSets give pods stable network identities (`postgres-0`, not `postgres-abc123`) and stable persistent volumes (the PVC follows the pod across restarts). Deployments treat pods as interchangeable, which is wrong for databases.

**Why a separate container:** Decoupling. The app pod can crash, restart, scale up/down — the database is untouched. The database can be backed up, patched, version-upgraded independently.

**Why one replica:** This is a lab — we're not running HA Postgres. In production you'd use Patroni or a managed DB (DigitalOcean Managed Databases, AWS RDS, etc.).

**Where:** `k8s/base/postgres-statefulset.yaml`, `k8s/base/postgres-service.yaml`

**What to say:** "Postgres runs in its own pod, in a StatefulSet, with a headless Service. The app connects to it via `jdbc:postgresql://postgres:5432/cloudapp` — Kubernetes DNS resolves `postgres` to the pod's IP. StatefulSet gives Postgres a stable identity, which matters because Postgres writes to a specific data directory."

**Demo:**
```bash
kubectl get pod -l app.kubernetes.io/name=postgres -o wide
kubectl exec postgres-0 -- psql -U cloudapp -d cloudapp -c "\dt"
kubectl exec postgres-0 -- psql -U cloudapp -d cloudapp -c "SELECT * FROM messages;"
```

---

### Requirement 14 — Storage mounted to the database container

**What:** A `volumeClaimTemplate` in the StatefulSet creates a `PersistentVolumeClaim` (PVC) of 2Gi. Kubernetes binds the PVC to a `PersistentVolume` (PV) backed by:
- Locally (kind): a hostPath on the host's filesystem (`standard` storage class)
- Remotely (DOKS): a DigitalOcean Block Storage volume (`do-block-storage` class)

**Why this matters:** If Postgres just wrote to the container's filesystem, all data would be lost when the pod restarts. The PVC is a separate resource that outlives the pod — it gets remounted when the pod restarts.

**Why a StatefulSet's `volumeClaimTemplate` and not a separate PVC:** StatefulSet creates one PVC per replica, with a predictable name (`data-postgres-0`). If you scale the StatefulSet up, each new replica gets its own PVC — perfect for sharded databases.

**Where:** `k8s/base/postgres-statefulset.yaml` (the `volumeClaimTemplates:` block at the bottom) and `k8s/remote/postgres-patch.yaml` (sets `storageClassName: do-block-storage`).

**What to say:** "The StatefulSet has a `volumeClaimTemplate` that creates a 2Gi PVC. Postgres mounts it at `/var/lib/postgresql/data`. When the pod restarts — for any reason: crash, node failure, image update — Kubernetes mounts the same PVC back. The data survives. I tested this: deleted the postgres-0 pod, waited for it to come back, queried the table — data was still there."

**Demo:**
```bash
kubectl get pvc
kubectl describe pvc data-postgres-0 | grep -E "StorageClass|Capacity|Used By"
# Prove persistence:
kubectl exec postgres-0 -- psql -U cloudapp -d cloudapp -tAc "SELECT count(*) FROM messages;"
kubectl delete pod postgres-0
kubectl wait --for=condition=ready pod/postgres-0 --timeout=120s
kubectl exec postgres-0 -- psql -U cloudapp -d cloudapp -tAc "SELECT count(*) FROM messages;"
# Same number both times.
```

---

## 4. Common examiner questions, with answers

**Q: Why Kubernetes and not just Docker Compose?**
A: Compose is for a single host. Kubernetes runs across many machines, gives you autoscaling, rolling updates, self-healing (a crashed pod is automatically replaced), and load balancing. Requirements 6, 7, 8, 10 are impossible with raw Compose.

**Q: What's the difference between a Service and an Ingress?**
A: A Service exposes pods to other things *inside* the cluster (ClusterIP). An Ingress exposes a Service to the *outside world* over HTTP — it terminates external requests, looks at the Host header and path, and routes to the right Service.

**Q: What's the difference between a Deployment and a StatefulSet?**
A: A Deployment treats pods as interchangeable cattle — any pod can serve any request, restart numbers are random (`app-7f8d-abc`). A StatefulSet treats pods as named pets with stable identities (`postgres-0`, `postgres-1`) and stable storage. Use StatefulSet for databases and other things that care about which pod they are.

**Q: Why use Kustomize instead of just having separate YAML for each env?**
A: DRY. The Deployment, Service, HPA are 95% the same between local and DOKS — only the image, ingress host, and storage class differ. Kustomize lets me write the shared parts once in `base/` and patch only the differences in overlays. If I add a new field to the Deployment, I add it once.

**Q: What's a Helm chart?**
A: A Helm chart is a templated bundle of Kubernetes YAML — variables, conditions, loops. I use Helm for the third-party stuff (ingress-nginx, kube-prometheus-stack, loki) because they're complex and the chart authors maintain them. I use plain Kustomize for my own manifests because they're simpler.

**Q: How does Prometheus discover targets?**
A: I deploy a `ServiceMonitor` resource (a CRD from the Prometheus Operator). The Prometheus pod watches for ServiceMonitors with specific labels (`release: monitoring`). When it finds one, it reads the selector and starts scraping any Service that matches.

**Q: What happens if Postgres dies?**
A: Kubernetes restarts the postgres-0 pod automatically. The PVC reattaches, so all data is intact. The app pods get `connection refused` for a few seconds while Postgres restarts. After it's back, their next request succeeds. If you wanted no downtime for the database itself, you'd run a multi-node Postgres cluster (Patroni, Stolon) or use a managed DB.

**Q: What's the difference between liveness and readiness probes?**
A: Liveness — "is the process alive?" If it fails, Kubernetes *restarts* the pod. Readiness — "can the app serve traffic?" If it fails, Kubernetes *removes the pod from the Service* but doesn't restart it. Important: during slow startup (Flyway migrations, DB connection pool warmup), readiness is OUT but liveness is UP — Kubernetes waits without killing the pod.

**Q: Why JSON logs?**
A: Loki parses JSON fields into queryable labels. With plain text, I'd have to write log parsing rules. JSON is the lazy correct answer.

**Q: Why Flyway and not Hibernate's schema generation?**
A: Hibernate `ddl-auto=update` is unsafe in production — it can drop columns silently. Flyway is migration-based: every schema change is a versioned SQL file in `db/migration/`. The migration history is tracked in a table; you can never accidentally run an old or out-of-order migration.

**Q: How do you handle secrets?**
A: Kubernetes Secrets. Locally, the credentials are baked into the overlay's `secretGenerator` — fine for a lab. In production / on DOKS, I read them from `.env.remote` (gitignored). A real production setup would use Sealed Secrets, SOPS, or an external secrets manager (HashiCorp Vault, AWS Secrets Manager).

**Q: How does the ingress-nginx pod actually receive external traffic?**
A: On DOKS, ingress-nginx's Service is `type: LoadBalancer`. The DigitalOcean cloud controller sees this and provisions a real Load Balancer with a public IP. Traffic arrives at the LB, gets forwarded to the ingress-nginx pod, which inspects the Host header and routes internally. On kind locally, we use `hostPort` (the kind node has port 28080 mapped to container port 80), which is a hack to simulate a LoadBalancer.

**Q: What's a CRD?**
A: Custom Resource Definition. Kubernetes lets you add new "kinds" of objects beyond the built-in ones (Pod, Service, Deployment...). `ServiceMonitor` is a CRD from the Prometheus Operator — it's not native Kubernetes, but the Prometheus Operator watches for them and configures Prometheus accordingly.

**Q: Why is the image pull policy `Always` on the remote overlay but `IfNotPresent` locally?**
A: Locally we build the image into the kind node directly (no pull) — `IfNotPresent` skips an unnecessary network call. On DOKS we pull from GHCR — `Always` ensures we get the newest `:latest` even if the same tag was pulled earlier. (Better practice would be to pin a specific SHA-tagged image and use `IfNotPresent`, but for the lab `latest` is fine.)

**Q: What does `revisionHistoryLimit: 10` mean? Where is the history stored?**
A: Kubernetes keeps the last 10 ReplicaSet objects for the Deployment. Each ReplicaSet has the pod template (image, env, resources) for that revision. `kubectl rollout undo` just scales the previous ReplicaSet up and the current one down.

**Q: How does the HPA actually measure CPU and memory?**
A: It queries the Metrics API. By default that's the `metrics-server` (a lightweight cluster aggregator). With kube-prometheus-stack, we get a more powerful version backed by Prometheus. The HPA reads pod metrics every 15 seconds and computes a moving average.

**Q: What's the difference between `replicas: 2` in the Deployment and HPA `minReplicas: 2`?**
A: They conflict if both try to manage the replica count. Best practice: once you add an HPA, *remove* the static `replicas` from the Deployment (or let the HPA win). In our setup the HPA always takes precedence at runtime, so `replicas: 2` in the Deployment is really just the starting value.

**Q: Why is the LoadBalancer expensive?**
A: A real Load Balancer is a separate piece of infrastructure (a small VM or hardware appliance) that DigitalOcean provisions and bills you for (~$12/mo). It's not part of the cluster — it lives in front of it. On a free local kind cluster we fake it with `hostPort`.

---

## 5. How to actually run the demo in front of the examiner

Have these terminals ready:

**Terminal 1 — the cluster is already up:**
```bash
# Sanity check
kubectl get all
curl http://localhost:28080/
curl -X POST http://localhost:28080/messages -H 'Content-Type: application/json' -d '{"text":"hi"}'
curl http://localhost:28080/messages
```

**Terminal 2 — for the rolling-update demo:**
```bash
while true; do curl -s -o /dev/null -w "%{http_code}\n" http://localhost:28080/; sleep 0.2; done
```

**Terminal 3 — for triggering things:**
```bash
# Scale demo
kubectl scale deployment/cloud-app --replicas=4
kubectl get pods -l app.kubernetes.io/name=cloud-app

# Rolling update demo (watch Terminal 2 stay at 200)
kubectl rollout restart deployment/cloud-app
kubectl rollout status deployment/cloud-app

# Rollback demo
kubectl rollout history deployment/cloud-app
kubectl rollout undo deployment/cloud-app

# Postgres persistence demo
kubectl exec postgres-0 -- psql -U cloudapp -d cloudapp -c "SELECT count(*) FROM messages;"
kubectl delete pod postgres-0
kubectl wait --for=condition=ready pod/postgres-0 --timeout=120s
kubectl exec postgres-0 -- psql -U cloudapp -d cloudapp -c "SELECT count(*) FROM messages;"
```

**Terminal 4 — Grafana port-forward:**
```bash
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
# Open browser: http://localhost:3000 (admin/admin)
# Click Dashboards → "Cloud App" → show HTTP rate going up while the curl loop is running
# Click Explore → Loki → {app_kubernetes_io_name="cloud-app"} → show live logs
```

---

## 6. If something breaks in the demo

**App doesn't respond on `curl localhost:28080`:**
```bash
kubectl get pods                          # Are pods Running?
kubectl describe pod <pod>                # Look at events
kubectl logs <pod>                        # Read the logs
```

**Pod stuck in CrashLoopBackOff:**
- Usually means readiness/liveness probe is failing, or the app can't reach Postgres.
- `kubectl logs <pod>` → look for "Connection refused" or stack traces.

**HPA shows `<unknown>` for CPU:**
- metrics-server needs ~30 seconds after pod startup to collect data. Wait.

**Examiner asks something I don't know:**
- Say: "Good question, let me check the manifest." Open the file, read it together. Honest > making it up.

---

## 7. Cheat sheet of the most-used commands

```bash
# State of the world
kubectl get all                                            # everything in the namespace
kubectl get pod -A                                         # pods across all namespaces
kubectl describe deploy cloud-app                          # deployment details
kubectl logs deploy/cloud-app --tail=50                    # recent logs

# Deploy / update
kubectl apply -k k8s/local                                 # deploy local overlay
kubectl rollout restart deployment/cloud-app               # force a fresh rollout
kubectl rollout status deployment/cloud-app                # wait until rollout is done

# Scale
kubectl scale deployment/cloud-app --replicas=N            # manual
kubectl get hpa cloud-app                                  # autoscaler status

# Rollback
kubectl rollout history deployment/cloud-app
kubectl rollout undo deployment/cloud-app
kubectl rollout undo deployment/cloud-app --to-revision=2

# Look inside
kubectl exec -it <pod> -- /bin/sh                          # shell into a pod
kubectl port-forward svc/cloud-app 8080:8080               # forward a service to localhost
kubectl describe pvc data-postgres-0                       # storage details

# Cleanup
kind delete cluster --name cloud-lab                       # nuke local cluster
bash scripts/teardown-remote.sh                            # nuke DOKS cluster
```

Print this. Keep it next to you during the defense.
