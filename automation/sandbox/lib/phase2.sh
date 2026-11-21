#!/usr/bin/env bash
# =============================================================================
# OpenG2P Deployment Automation — Phase 2: Platform Components (Helmfile)
# =============================================================================
# Installs Istio (or, with edge: apisix, APISIX), Rancher, Monitoring, and
# Logging on the K8s cluster using Helmfile. Sourced by roles/infra/run.sh — do not run directly.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Install Istio via istioctl (not Helm — Istio uses its own installer)
# ─────────────────────────────────────────────────────────────────────────────
install_istio_if_needed() {
    local step_id="phase2.istio"

    if is_step_done "$step_id" && [[ "$FORCE_MODE" != "true" ]]; then
        log_info "Skipping Istio installation — already completed."
        return 0
    fi

    if kubectl -n istio-system get deployment istiod &>/dev/null; then
        log_success "Istio (istiod) is already deployed."
        mark_step_done "$step_id"
        return 0
    fi

    log_info "Installing Istio via istioctl..."
    local istio_operator="${SCRIPT_DIR}/charts/istio-install/templates/operator.yaml"

    if [[ ! -f "$istio_operator" ]]; then
        log_error "Istio operator YAML not found at ${istio_operator}" \
                  "The automation charts directory may be incomplete" \
                  "Ensure the charts/istio-install directory exists"
        return 1
    fi

    istioctl install -f "$istio_operator" -y || {
        log_error "istioctl install failed" \
                  "Istio could not be installed on the cluster" \
                  "Check cluster access and istioctl version" \
                  "istioctl version; kubectl get nodes"
        return 1
    }

    wait_for_deployment "istio-system" "istiod" 300 || return 1
    wait_for_command "Istio ingress gateway pods" \
        "kubectl -n istio-system get pods -l istio=ingressgateway -o jsonpath='{.items[*].status.phase}' | grep -q Running" \
        300 10

    mark_step_done "$step_id"
    log_success "Istio installed and healthy."
}

# ─────────────────────────────────────────────────────────────────────────────
# edge: apisix — local-path StorageClass for APISIX's etcd (etcd must not run on
# NFS) and the APISIX values file
# ─────────────────────────────────────────────────────────────────────────────
LOCAL_PATH_PROVISIONER_URL="https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml"

install_local_path_if_needed() {
    if kubectl get storageclass local-path &>/dev/null; then
        log_success "StorageClass local-path already exists."
        return 0
    fi
    log_info "Installing local-path-provisioner (StorageClass local-path, for APISIX's etcd)..."
    kubectl apply -f "$LOCAL_PATH_PROVISIONER_URL" || {
        log_error "local-path-provisioner could not be installed" \
                  "kubectl apply of ${LOCAL_PATH_PROVISIONER_URL} failed" \
                  "Check outbound access to raw.githubusercontent.com" \
                  "kubectl apply -f ${LOCAL_PATH_PROVISIONER_URL}"
        return 1
    }
    # nfs-csi stays the default StorageClass; local-path is used only where it is named.
    wait_for_deployment "local-path-storage" "local-path-provisioner" 300 || return 1
}

# The staged copy (orchestrator) wins; on-box runs use apisix.values_file as given.
apisix_values_path() {
    if [[ -f "${SCRIPT_DIR}/apisix-values.yaml" ]]; then
        echo "${SCRIPT_DIR}/apisix-values.yaml"
    else
        local path=$(cfg 'apisix.values_file' '')
        [[ -n "$path" && -f "$path" ]] && echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Generate helmfile-infra-values.yaml from config
# ─────────────────────────────────────────────────────────────────────────────
generate_helmfile_infra_values() {
    local values_file="${SCRIPT_DIR}/helmfile-infra-values.yaml"
    local rancher_host=$(get_rancher_hostname)

    # Loki's dedicated MinIO root password: prefer the config value, else reuse a
    # previously persisted one, else generate + persist (stable across re-runs).
    local secrets_dir="/etc/openg2p/secrets"
    local loki_minio_pw_file="${secrets_dir}/loki-minio.env"
    local loki_minio_pw
    loki_minio_pw=$(cfg 'loki_minio_root_password')
    if [[ -z "$loki_minio_pw" ]]; then
        if [[ -f "$loki_minio_pw_file" ]]; then
            loki_minio_pw=$(grep '^LOKI_MINIO_ROOT_PASSWORD=' "$loki_minio_pw_file" | cut -d= -f2-)
        else
            loki_minio_pw=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
            mkdir -p "$secrets_dir" && chmod 0700 "$secrets_dir"
            echo "LOKI_MINIO_ROOT_PASSWORD=${loki_minio_pw}" > "$loki_minio_pw_file"
            chmod 0600 "$loki_minio_pw_file"
        fi
    fi

    cat > "$values_file" <<EOF
# Auto-generated from infra config — do not edit manually
# Generated at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

rancher_hostname: "${rancher_host}"
node_ip: "$(cfg 'node_ip')"

# nginx: host nginx + Istio (OpenG2P). apisix: APISIX holds 80/443 and serves Rancher.
edge: "$(cfg 'edge' 'nginx')"
# local: Grafana, Loki and OpenTelemetry here. external: none of them; logs go elsewhere.
logging: "$(cfg 'logging' 'local')"
apisix:
  chartVersion: "$(cfg 'apisix.chart_version' '')"
  valuesFile: "$(apisix_values_path)"
  tlsSecretName: "$(cfg 'tls.k8s_secret' '' | cut -d/ -f2)"
  domain: "$(cfg 'domain')"
  # Rancher answers only these sources, as the nginx edge's allowlist (WireGuard, VPC, pods).
  privateAllowlist: "$(nginx_private_allowlist | awk '$1 == "allow" { sub(";", "", $2); printf "%s%s", sep, $2; sep = "," }')"

rancher:
  version: "$(cfg 'rancher.version' '2.15.1')"
  replicas: $(cfg 'rancher.replicas' '1')

# Observability — Grafana Loki log store + its dedicated MinIO object store.
loki:
  retentionHours: $(cfg 'loki_retention_hours' '168')
  minio:
    rootUser:     "$(cfg 'loki_minio_root_user' 'loki')"
    rootPassword: "${loki_minio_pw}"
    size:         "$(cfg 'loki_minio_size' '50Gi')"

# Alerting notification channels. Empty value => that channel stays inactive.
alerting:
  slack:
    webhookUrl: "$(cfg 'alert_slack_webhook_url' '')"
    channel:    "$(cfg 'alert_slack_channel' '#alerts')"
  smtp:
    smarthost:  "$(cfg 'alert_smtp_smarthost' '')"
    from:       "$(cfg 'alert_smtp_from' '')"
    username:   "$(cfg 'alert_smtp_username' '')"
    password:   "$(cfg 'alert_smtp_password' '')"
    to:         "$(cfg 'alert_smtp_to' '')"
  telegram:
    botToken:   "$(cfg 'alert_telegram_bot_token' '')"
    chatId:     "$(cfg 'alert_telegram_chat_id' '')"

# Optional AI layer (OFF by default).
ai:
  enabled: $(cfg 'ai_enabled' 'false')
  openrouterApiKey: "$(cfg 'ai_openrouter_api_key' '')"
  model: "$(cfg 'ai_model' 'openrouter/qwen/qwen-2.5-72b-instruct')"
EOF

    log_success "Helmfile infra values generated at ${values_file}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run Phase 2: Istio + Helmfile sync
# ─────────────────────────────────────────────────────────────────────────────
run_phase2() {
    log_step "2" "Phase 2 — Platform Components (Helmfile)"

    ensure_kubeconfig || return 1

    log_info "Verifying Kubernetes cluster is healthy..."
    if ! kubectl get nodes | grep -qw Ready; then
        log_error "Kubernetes node is not in Ready state" \
                  "RKE2 may still be initializing" \
                  "Check node status and RKE2 logs" \
                  "kubectl get nodes; journalctl -u rke2-server -n 30"
        return 1
    fi
    log_success "Kubernetes cluster is healthy."

    if [[ "$(cfg 'edge' 'nginx')" == "apisix" ]]; then
        install_local_path_if_needed || return 1
        if [[ -z "$(apisix_values_path)" || -z "$(cfg 'apisix.chart_version' '')" ]]; then
            log_error "edge: apisix needs apisix.values_file and apisix.chart_version" \
                      "APISIX is installed from oan-helm with the environment's values" \
                      "Set both in the config (see environments/qa/platform-config.example.yaml)"
            return 1
        fi
    else
        install_istio_if_needed || return 1
    fi
    generate_helmfile_infra_values

    log_info "Running Helmfile sync for platform components..."
    log_info "This may take 10-20 minutes on first run."
    cd "${SCRIPT_DIR}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would execute: helmfile -f helmfile-infra.yaml.gotmpl sync"
        helmfile -f helmfile-infra.yaml.gotmpl diff 2>/dev/null || log_warn "helmfile diff may fail on first run (expected)."
        return 0
    fi

    helmfile -f helmfile-infra.yaml.gotmpl sync 2>&1 | tee -a "$LOG_FILE" || {
        log_error "Helmfile sync failed" \
                  "One or more Helm releases failed to install" \
                  "Review the output above for specific errors" \
                  "helmfile -f helmfile-infra.yaml.gotmpl sync --debug 2>&1 | tail -50"
        echo ""
        log_info "Troubleshooting tips:"
        log_info "  1. Check pod status:  kubectl get pods -A | grep -v Running"
        log_info "  2. Check events:      kubectl get events -A --sort-by=.lastTimestamp | tail -20"
        log_info "  3. Re-run to retry:   sudo $0 --config $(basename "$CONFIG_FILE")"
        return 1
    }

    log_success "Phase 2 complete — all platform components deployed."
}
