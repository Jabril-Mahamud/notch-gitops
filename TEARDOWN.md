# Teardown

Goal: zero billable AWS resources when the cluster is down.

`eksctl delete cluster` does **not** get you there on its own. Work through the
ordered steps below, then run the verification block at the end.

## What survives `eksctl delete cluster`

eksctl deletes the CloudFormation stacks it created (control plane, nodegroups,
VPC) and — confirmed in `pkg/actions/cluster/delete.go` — it also calls
`elb.Cleanup`, which lists Kubernetes `Service` and `Ingress` objects and deletes
their load balancers first. Anything created outside CloudFormation by a
controller *other* than that path is left behind.

| Resource | Survives? | Bills? | Approx eu-west-1 |
|---|---|---|---|
| EKS control plane | no | — | $0.10/hr while up |
| Nodegroup EC2 + root volumes | no | — | — |
| **ingress-nginx NLB** | **no**, eksctl deletes it | — | ~$16/mo while up |
| **CNPG PVC's EBS volume** | **YES** | **yes** | ~$0.90/mo per 10 GiB |
| ECR repositories + images | **YES** (`deletionPolicy: Orphan`) | yes | $0.10/GB-mo |
| Secrets Manager secrets | **YES** | yes | $0.40/secret/mo |
| IAM roles, policies, OIDC provider | **YES** | no | free |
| CloudWatch log groups | **YES** if control-plane logging was on | yes | not enabled here |

Two important caveats on the NLB:

- eksctl can only delete it while the Kubernetes API is still reachable. The
  source logs `deleting a cluster requires permission to list Kubernetes Services`
  and bails otherwise. If the cluster is already broken, the NLB leaks — delete
  the Service yourself first (step 3).
- A leaked NLB holds ENIs in the VPC, which makes the VPC stack deletion hang
  rather than fail quietly. A stuck `eksctl delete` usually means this.

The EBS volume is the one that leaks *silently*. Nothing blocks, nothing errors,
you just keep paying about a pound a month per volume.

## Preserving the database

**You do not get to keep the EBS volume across a teardown.** Carrying it over
means either leaving the volume allocated (still billing) or taking a snapshot
(~$0.05/GB-month, and restoring it into a fresh CNPG cluster needs
`bootstrap.recovery` wiring this repo does not have).

Take a logical dump instead. It costs nothing to store locally.

```bash
# Before teardown
kubectl exec -n platform-db notch-pg-1 -c postgres -- \
  pg_dump -U postgres -d notch --clean --if-exists \
  > "notch-$(date +%F).sql"
```

```bash
# After rebuild, once Crossplane has recreated the database and role
kubectl wait --for=condition=Ready -n platform-db cluster/notch-pg --timeout=10m
kubectl exec -i -n platform-db notch-pg-1 -c postgres -- \
  psql -U postgres -d notch < notch-2026-08-16.sql
```

If you skip the dump, the rebuild comes up with an empty `notch` database and
whatever schema your migrations create. That is the intended default.

## Teardown, in order

Order matters: ArgoCD self-heals, so it has to stop reconciling before you delete
anything it manages, or it will recreate the Service and the PVC underneath you.

**1. Dump the database** (skip if you don't want the data — see above).

**2. Stop ArgoCD reconciling.**

```bash
kubectl delete ns argocd --wait
```

Applications are namespaced, so this removes them along with the controllers.
They carry no `resources-finalizer.argocd.argoproj.io`, so this deliberately does
**not** cascade into the workloads — you delete those explicitly next, in an
order you control.

**3. Release the NLB.**

```bash
kubectl delete svc -n ingress-nginx ingress-nginx-controller --wait
```

Wait for it to actually go before moving on; the AWS-side delete is async.

```bash
aws elbv2 describe-load-balancers --region eu-west-1 \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s')].[LoadBalancerName,State.Code]" \
  --output table
```

**4. Release the EBS volume.**

CNPG sets an ownerReference from the PVC to the Cluster, so deleting the Cluster
should take the PVC with it, and the default `gp2` StorageClass has
`reclaimPolicy: Delete`, so the CSI driver then deletes the volume. Verify rather
than assume — a PVC left behind here is exactly the silent leak.

```bash
kubectl delete cluster.postgresql.cnpg.io -n platform-db notch-pg --wait
kubectl get pvc -n platform-db          # expect: No resources found
kubectl delete pvc -n platform-db --all # only if the above listed anything
```

Confirm the StorageClass really is `Delete` before trusting step 4:

```bash
kubectl get sc -o custom-columns=NAME:.metadata.name,RECLAIM:.reclaimPolicy,DEFAULT:.metadata.annotations."storageclass\.kubernetes\.io/is-default-class"
```

**5. Delete the cluster.**

```bash
eksctl delete cluster -f ../notch/cluster.yaml --wait
```

**6. Delete the ECR repositories** — they are `deletionPolicy: Orphan`, so
Crossplane deliberately left them alone. Skip this if you want to keep the images
and avoid rebuilding them (a few hundred MB is pennies a month).

```bash
aws ecr delete-repository --repository-name notch-frontend --force --region eu-west-1
aws ecr delete-repository --repository-name notch-backend  --force --region eu-west-1
```

**7. Delete the Secrets Manager secrets** — $0.40/month each. `--force-delete-without-recovery`
skips the 7-day recovery window; drop that flag if you want the window.

```bash
aws secretsmanager delete-secret --secret-id notch/dev/platform/postgres-superuser \
  --force-delete-without-recovery --region eu-west-1
```

List anything else under the prefix first:

```bash
aws secretsmanager list-secrets --region eu-west-1 \
  --query "SecretList[?starts_with(Name,'notch/')].Name" --output table
```

## Verification — nothing left billing

Run all of these. Every one should come back empty.

```bash
# Catch-all: anything still tagged for this cluster
aws resourcegroupstaggingapi get-resources --region eu-west-1 \
  --tag-filters Key=kubernetes.io/cluster/notch-mgmt \
  --query 'ResourceTagMappingList[].ResourceARN' --output table

# EKS cluster
aws eks list-clusters --region eu-west-1 --output table

# CloudFormation stacks
aws cloudformation list-stacks --region eu-west-1 \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE DELETE_FAILED \
  --query "StackSummaries[?starts_with(StackName,'eksctl-notch-mgmt')].[StackName,StackStatus]" \
  --output table

# EBS volumes from PVCs - the silent leak
aws ec2 describe-volumes --region eu-west-1 \
  --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name \
  --query 'Volumes[].[VolumeId,State,Size,Tags[?Key==`kubernetes.io/created-for/pvc/namespace`]|[0].Value]' \
  --output table

# Any unattached volume at all
aws ec2 describe-volumes --region eu-west-1 \
  --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table

# Load balancers
aws elbv2 describe-load-balancers --region eu-west-1 \
  --query 'LoadBalancers[].[LoadBalancerName,Type,State.Code]' --output table
aws elb describe-load-balancers --region eu-west-1 \
  --query 'LoadBalancerDescriptions[].LoadBalancerName' --output table

# Snapshots (only if you took one)
aws ec2 describe-snapshots --owner-ids self --region eu-west-1 \
  --query 'Snapshots[].[SnapshotId,VolumeSize,StartTime]' --output table

# Elastic IPs (should be none - NAT is disabled)
aws ec2 describe-addresses --region eu-west-1 \
  --query 'Addresses[].[PublicIp,AllocationId]' --output table

# ECR, if you deleted it in step 6
aws ecr describe-repositories --region eu-west-1 \
  --query 'repositories[].repositoryName' --output table

# Secrets, if you deleted them in step 7
aws secretsmanager list-secrets --region eu-west-1 \
  --query "SecretList[?starts_with(Name,'notch/')].Name" --output table
```

IAM roles (`notch-eso`, `notch-crossplane-aws`) and the OIDC provider survive and
cost nothing. eksctl removes them with the cluster stack; if a `DELETE_FAILED`
stack left them behind, they are harmless to keep and will be reused on rebuild.

```bash
aws iam list-roles --query "Roles[?starts_with(RoleName,'notch')].RoleName" --output table
```
