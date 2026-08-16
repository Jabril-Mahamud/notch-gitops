# notch-gitops

GitOps state for Notch. Cluster manifests, Helm values, Crossplane resources.
The `notch-app` chart itself lives in the sibling `notch` repo.

## Layout

```
platform/root.yaml            bootstrap Application, applied by hand
platform/addons/              everything root syncs (recursive)
  crossplane/                 Providers + DeploymentRuntimeConfig
  infra/                      ProviderConfigs, ECR repos, Postgres
  applicationset.yaml         generates one Application per services/<name>/<env>
  apps-root.yaml              syncs platform/apps
platform/apps/notch/          per-service Crossplane resources (database, role, grant)
envs/<env>/services.common.yaml   values for every service in an env
services/<name>/service.yaml      values for one service, every env
services/<name>/<env>/values.yaml values for one service, one env
```

The ApplicationSet globs `services/*/*/values.yaml` and layers all three value
files onto the chart. A service exists once those three files exist.

## Bootstrap

Order matters. Steps 1 and 2 are manual and must both precede step 4.

**1. Create the cluster.** eksctl creates the IRSA roles that external-secrets
and Crossplane later assume, so it has to run first.

```bash
eksctl create cluster -f ../notch/cluster.yaml
```

**2. Create the Postgres superuser secret.** `platform/addons/infra/postgres.yaml`
reads this; CloudNativePG will not start without it.

```bash
aws secretsmanager create-secret \
  --name notch/dev/platform/postgres-superuser \
  --secret-string '{"password":"'"$(openssl rand -base64 24)"'"}' \
  --region eu-west-1
```

**3. Install ArgoCD.** Bootstrap only; from then on it manages itself via
`platform/addons/argocd.yaml`.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace --version 10.2.1
```

**4. Apply root.** Everything else follows from here.

```bash
kubectl apply -f platform/root.yaml
```

## Sync waves

Root syncs `platform/addons` recursively as one Application, so ordering is by
wave rather than by dependency graph:

| Wave | What |
|-----:|------|
| -1 | Crossplane |
| 0 | external-secrets, reloader, ingress-nginx, CloudNativePG, DeploymentRuntimeConfig |
| 1 | ClusterSecretStore, Crossplane Providers, `platform-db` namespace |
| 2 | AWS ProviderConfig, Postgres superuser ExternalSecret |
| 3 | ECR repositories, CloudNativePG Cluster |
| 4 | provider-sql ProviderConfig |
| 5 | ApplicationSet (generates the service Applications) |
| 10 | ArgoCD self-management |
| 20 | `platform/apps` (database, role, grant) |

## Secrets

Two separate secrets per service, deliberately:

- `<service>-secrets` — owned by external-secrets, synced from
  `notch/<env>/apps/<service>/*` in AWS Secrets Manager. `creationPolicy: Owner`,
  so nothing else may write to it.
- `notch-db` — written by Crossplane's `Role`. Wired into individual containers
  via `containers.<name>.envSecrets`, which is how the backend gets database
  credentials and the frontend does not.

Add an app secret by creating it in Secrets Manager under the service prefix;
external-secrets picks it up within `refreshInterval` and reloader restarts the pods.

## Reaching a service

`ingress-nginx` provisions an internet-facing NLB. `notch.dev.local` does not
resolve publicly, so test against the load balancer directly:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
curl -H "Host: notch.dev.local" http://<that-hostname>/
```

Point a real DNS record at the NLB and update `services/notch/service.yaml` when
you want a permanent hostname.
