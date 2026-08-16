# notch-gitops

GitOps state for Notch. Cluster manifests, Helm values, Crossplane resources.
No chart and no application code — three repos, split by lifecycle:

| Repo | Holds |
|---|---|
| [notch](https://github.com/Jabril-Mahamud/notch) | `cluster.yaml`, the `notch-app` chart |
| **notch-gitops** (this one) | ArgoCD root, addons, Crossplane resources, per-service values |
| [notch-fe-app](https://github.com/Jabril-Mahamud/notch-fe-app) | The Notch application and the CI that pushes its images to ECR |

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

Order matters. Steps 1 to 3 are manual and must all precede step 5.

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

**3. Create at least one app secret.** The ExternalSecret uses a `find`
generator: with nothing under the prefix it has nothing to sync. The backend
also refuses to start without `NOTCH_JWT_SECRET`, so create that one.

```bash
aws secretsmanager create-secret \
  --name notch/dev/apps/notch/NOTCH_JWT_SECRET \
  --secret-string "$(openssl rand -base64 32)" \
  --region eu-west-1
```

**4. Install ArgoCD.** Bootstrap only; from then on it manages itself via
`platform/addons/argocd.yaml`.

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace --version 10.2.1
```

**5. Apply root.** Everything else follows from here.

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

## Images

`platform/addons/infra/ecr-repos.yaml` declares the two ECR repositories, but
they already exist — they were created by hand from notch-fe-app's
`.github/aws/bootstrap.sh` so CI had somewhere to push before this cluster had
ever run. Each carries a `crossplane.io/external-name` annotation; without it
Crossplane treats the repository as new and the create fails with
`RepositoryAlreadyExistsException`. With it, it adopts the existing one.

`deletionPolicy: Orphan` on both, so pruning the manifest never takes the images
with it.

Tags come from the notch-fe-app workflow: `dev-<sha>` and `dev-latest` on push
to `main`. `services/notch/dev/values.yaml` pins `dev-latest`.

## Outstanding before the first cluster

Not yet in this repo, and the bootstrap will not get far without them:

- **gp3 StorageClass**, set default, in `platform/addons/infra/`. EKS ships gp2
  as default; the CNPG `Cluster` in `postgres.yaml` has no `storageClass` set and
  needs to point at gp3.
- **ingress-nginx `use-forwarded-headers`**. Without it the backend's per-IP rate
  limit keys on the ingress controller's pod IP, which makes it one shared bucket
  for every client. The backend already runs uvicorn with `--proxy-headers`, so
  this is the other half of that fix.

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
