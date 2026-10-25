#!/usr/bin/env bash
# Destroy your EKS voting app cluster and all associated AWS and Kubernetes resources.
# Usage: ./down.sh <unique_id> [env_tag]

set -euo pipefail

UNIQUE_ID="${1:-}"
ENV_TAG="${2:-dev}"
REGION="${AWS_REGION:-us-east-1}"

if [[ -z "$UNIQUE_ID" ]]; then
  echo "Error: Unique ID / student name is required."
  echo "Usage: ./down.sh <unique_id> [env_tag]"
  exit 1
fi

NAME_PREFIX="${UNIQUE_ID}-${ENV_TAG}"
CLUSTER_NAME="${NAME_PREFIX}-cluster"

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

warn() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2
}

for tool in terraform aws kubectl; do
  if ! command -v "$tool" &> /dev/null; then
    echo "Error: Required tool '$tool' is not installed."
    exit 1
  fi
done

TF_VARS=(-var "unique_id=${UNIQUE_ID}" -var "env_tag=${ENV_TAG}" -var "aws_region=${REGION}")

log "Initializing Terraform..."
terraform init -input=false >/dev/null

cleanup_guardduty() {
  local vpc_id="$1" endpoints sg i
  endpoints="$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=service-name,Values=com.amazonaws.${REGION}.guardduty-data" \
    --query "VpcEndpoints[?State!='deleted' && State!='deleting'].VpcEndpointId" --output text)"
  if [[ -n "$endpoints" ]]; then
    log "Removing GuardDuty VPC endpoint: ${endpoints}"
    aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids $endpoints >/dev/null
  fi

  sg="$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=GuardDutyManagedSecurityGroup-*" \
    --query 'SecurityGroups[].GroupId' --output text)"
  [[ -n "$sg" ]] || return 0

  log "Removing GuardDuty security group ${sg}..."
  for ((i = 0; i < 30; i++)); do
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg" >/dev/null 2>&1 && return 0
    sleep 10
  done
  warn "Could not delete security group ${sg} automatically."
}

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  log "Connecting kubectl to cluster ${CLUSTER_NAME}..."
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" --alias "$CLUSTER_NAME" >/dev/null

  log "Deleting Kubernetes Ingresses and LoadBalancer Services..."
  kubectl delete ingress --all --all-namespaces --timeout=120s 2>/dev/null || true
  kubectl get svc --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
    while read -r ns svc; do
      [[ -n "$svc" ]] || continue
      kubectl delete svc "$svc" -n "$ns" --timeout=60s 2>/dev/null || true
    done

  log "Deleting PersistentVolumeClaims..."
  kubectl delete pvc --all --all-namespaces --wait=false 2>/dev/null || true
  
  for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [[ "$ns" == kube-* || "$ns" == "kube-system" || "$ns" == "kube-node-lease" || "$ns" == "default" ]] || kubectl delete pods --all -n "$ns" --wait=false 2>/dev/null || true
  done
  
  if [[ -n "$(kubectl get pv -o name 2>/dev/null)" ]]; then
    kubectl wait --for=delete pv --all --timeout=120s 2>/dev/null || true
  fi
else
  log "Cluster not found, skipping Kubernetes cleanup."
fi

VPC_ID="$(terraform output -raw vpc_id 2>/dev/null || true)"

log "Destroying EKS cluster..."
terraform destroy -input=false -auto-approve "${TF_VARS[@]}" -target=module.eks || true

[[ -n "$VPC_ID" ]] && cleanup_guardduty "$VPC_ID"

log "Destroying remaining infrastructure..."
terraform destroy -input=false -auto-approve "${TF_VARS[@]}"

log "Cleaning up local kubeconfig context..."
kubectl config delete-context "$CLUSTER_NAME" >/dev/null 2>&1 || true

log "Done."