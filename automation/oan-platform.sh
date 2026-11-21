#!/usr/bin/env bash
# =============================================================================
# OAN platform — the cluster-level pieces the services are deployed into
# =============================================================================
# Runs after the platform install (automation/sandbox with edge: apisix) and applies
# environments/<env>/platform.yaml: the namespaces with their Pod Security labels and
# NetworkPolicies, the shared Frappe PostgreSQL, the ServiceAccount Jenkins deploys with, and the
# log agent (oan-logging) that ships to the central Loki and Grafana.
# The services themselves are not installed here; Jenkins deploys them from their repositories.
#
# Usage (as a cluster admin, with kubectl, helm and helmfile; KUBECONFIG pointing at the cluster):
#   ./automation/oan-platform.sh environments/qa
# Idempotent: re-run it after changing anything under environments/<env>/.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/utils.sh
source "${HERE}/lib/utils.sh"

ENV_DIR="$(cd "${1:?usage: oan-platform.sh <environments/env>}" && pwd)"
GUARD_CHART="${ENV_DIR}/charts/namespace-guard"

for bin in kubectl helm helmfile; do
    command -v "$bin" >/dev/null || { log_error "${bin} not found" \
        "This script applies Helm releases with helmfile" "Install ${bin} and re-run"; exit 1; }
done
kubectl get nodes >/dev/null || { log_error "No access to the cluster" \
    "kubectl get nodes failed" "Set KUBECONFIG (over WireGuard) or run on the node"; exit 1; }

# An empty endpoint would leave the log agent retrying forever with nowhere to send.
if [[ -f "${ENV_DIR}/values/oan-logging.yaml" ]] \
   && grep -qE '^\s*endpoint:\s*""\s*$' "${ENV_DIR}/values/oan-logging.yaml"; then
    log_error "The log agent has no endpoint" \
        "otel-agent.alternateConfig.exporters.otlp.endpoint is empty in values/oan-logging.yaml" \
        "Set it to <host>:<port> of the central OTel gateway"
    exit 1
fi

# The platform install already created some of these namespaces (api6-gateway for the certificate and APISIX).
# Helm refuses to take over an object it did not create unless the object carries its ownership metadata.
log_info "Handing existing namespaces to release namespace-guard..."
namespaces=$(helm template namespace-guard "$GUARD_CHART" -s templates/namespaces.yaml \
    | awk '/^kind: Namespace/ { ns = 1 } ns && /^  name:/ { print $2; ns = 0 }')
for ns in $namespaces; do
    kubectl get namespace "$ns" >/dev/null 2>&1 || continue
    kubectl label namespace "$ns" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
    kubectl annotate namespace "$ns" meta.helm.sh/release-name=namespace-guard \
        meta.helm.sh/release-namespace=kube-system --overwrite >/dev/null
done

log_info "Applying ${ENV_DIR}/platform.yaml..."
helmfile -f "${ENV_DIR}/platform.yaml" sync

log_success "OAN platform applied."
log_info "Jenkins kubeconfig: run cluster/write-kubeconfig.sh from oan-service-helm for ServiceAccount"
log_info "  $(awk '/^  name:/ { print $2; exit }' "${ENV_DIR}/values/oan-cluster-access.yaml") in namespace a2c, and store it as a Jenkins Secret file credential."
