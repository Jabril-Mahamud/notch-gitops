#!/usr/bin/env bash
# Bring up Notch on a local Kind cluster. Safe to re-run.
# Tear down: kind delete cluster --name notch
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=notch
APP=${APP:-../notch-fe-app}

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --config kind.yaml
kubectl config use-context "kind-$CLUSTER"

# Images: built locally, never pulled. Tag must match services/notch/local/values.yaml.
for c in frontend backend; do
  docker build -t "notch-$c:local" "$APP/$c"
  kind load docker-image "notch-$c:local" --name "$CLUSTER"
done

# Secrets ESO would sync on AWS. Only created when missing: regenerating the
# superuser password would lock provider-sql out of an initialised database.
secret() { # namespace name type key=value...
  local ns=$1 name=$2 type=$3; shift 3
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$ns" get secret "$name" >/dev/null 2>&1 && return
  kubectl -n "$ns" create secret generic "$name" --type="$type" \
    $(printf -- '--from-literal=%s ' "$@")
}
secret platform-db notch-pg-superuser kubernetes.io/basic-auth \
  username=postgres "password=$(openssl rand -hex 24)" \
  endpoint=notch-pg-rw.platform-db.svc.cluster.local port=5432
secret notch notch-secrets Opaque "NOTCH_JWT_SECRET=$(openssl rand -hex 32)"

# ArgoCD bootstrap; it manages itself from platform/addons/argocd.yaml after this.
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version 10.2.1 --wait

kubectl apply -f clusters/kind.yaml

cat <<EOF

Notch is syncing. Watch:   kubectl -n argocd get applications -w
ArgoCD UI:                 kubectl -n argocd port-forward svc/argocd-server 8443:443
Password:                  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
App, once synced:          http://notch.localhost:8080
EOF
