#!/usr/bin/env bash
# =============================================================================
# OAN platform — the cluster-level pieces the services are deployed into
# =============================================================================
# Runs after the platform install (automation/sandbox with edge: apisix) and applies
# oan-platform.yaml.gotmpl: the namespaces with their Pod Security labels and NetworkPolicies,
# the shared Frappe PostgreSQL, the ServiceAccount Jenkins deploys with, and the log agent
# (oan-logging) that ships to the central Loki and Grafana. Charts and values come from oan-helm
# (oan_helm.ref, oan_helm.environment); this repository holds neither.
# The services themselves are not installed here; Jenkins deploys them from their repositories.
#
# Usage (as a cluster admin, with kubectl, helm and helmfile; KUBECONFIG pointing at the cluster):
#   ./automation/oan-platform.sh environments/qa/platform-config.yaml
# Idempotent: re-run it after moving oan_helm.ref or a version in oan_platform.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/utils.sh
source "${HERE}/lib/utils.sh"

CONFIG_FILE="${1:?usage: oan-platform.sh <platform-config.yaml>}"
load_config "$CONFIG_FILE"

ref=$(cfg 'oan_helm.ref')
env_name=$(cfg 'oan_helm.environment')
for key in oan_helm.ref oan_helm.environment oan_platform.namespace_guard oan_platform.frappe_common \
           oan_platform.cluster_access oan_platform.logging; do
    [[ -n "$(cfg "$key")" ]] || { log_error "${key} is not set" \
        "The charts and values come from oan-helm at a fixed commit and chart versions" \
        "Set ${key} in ${CONFIG_FILE} (see environments/qa/platform-config.example.yaml)"; exit 1; }
done
values_raw="https://raw.githubusercontent.com/Centre-for-Open-Societal-Systems/oan-helm/${ref}/environments/${env_name}/values"

for bin in kubectl helm helmfile curl; do
    command -v "$bin" >/dev/null || { log_error "${bin} not found" \
        "This script applies Helm releases with helmfile" "Install ${bin} and re-run"; exit 1; }
done
kubectl get nodes >/dev/null || { log_error "No access to the cluster" \
    "kubectl get nodes failed" "Set KUBECONFIG (over WireGuard) or run on the node"; exit 1; }

# An empty endpoint would leave the log agent retrying forever with nowhere to send.
if curl -fsSL "${values_raw}/oan-logging.yaml" | grep -qE '^\s*endpoint:\s*""\s*$'; then
    log_error "The log agent has no endpoint" \
        "otel-agent.alternateConfig.exporters.otlp.endpoint is empty in oan-helm environments/${env_name}/values/oan-logging.yaml at ${ref}" \
        "Set it in oan-helm to <host>:<port> of the central OTel gateway, then move oan_helm.ref to that commit"
    exit 1
fi

# The platform install already created some of these namespaces (api6-gateway for the certificate and APISIX).
# Helm refuses to take over an object it did not create unless the object carries its ownership metadata.
log_info "Handing existing namespaces to release oan-namespace-guard..."
namespaces=$(curl -fsSL "${values_raw}/oan-namespace-guard.yaml" \
    | awk '/^namespaces:/ { in_ns = 1; next } /^[^ #]/ { in_ns = 0 } in_ns && /^  [a-z0-9-]+:/ { sub(":", "", $1); print $1 }')
for ns in $namespaces; do
    kubectl get namespace "$ns" >/dev/null 2>&1 || continue
    kubectl label namespace "$ns" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
    kubectl annotate namespace "$ns" meta.helm.sh/release-name=oan-namespace-guard \
        meta.helm.sh/release-namespace=kube-system --overwrite >/dev/null
done

state=$(mktemp)
trap 'rm -f "$state"' EXIT
cat > "$state" <<EOF
oanHelm:
  ref: "${ref}"
  environment: "${env_name}"
versions:
  namespaceGuard: "$(cfg 'oan_platform.namespace_guard')"
  frappeCommon: "$(cfg 'oan_platform.frappe_common')"
  clusterAccess: "$(cfg 'oan_platform.cluster_access')"
  logging: "$(cfg 'oan_platform.logging')"
EOF

log_info "Applying the OAN platform releases from oan-helm ${ref} (environments/${env_name})..."
helmfile -f "${HERE}/oan-platform.yaml.gotmpl" --state-values-file "$state" sync

log_success "OAN platform applied."
log_info "Jenkins kubeconfig: run cluster/write-kubeconfig.sh from oan-service-helm for the ServiceAccount in"
log_info "  oan-helm environments/${env_name}/values/oan-cluster-access.yaml (namespace a2c), and store it in Jenkins."
