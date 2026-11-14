#!/usr/bin/env bash
# =============================================================================
# OAN dev — Let's Encrypt wildcard for APISIX, through the sandbox ACME library
# =============================================================================
# Issues `<domain>` and `*.<domain>` with acme.sh (DNS-01) and applies the result as the
# Kubernetes TLS Secret APISIX serves (ApisixTls `secret`). It is the sandbox's
# lib/acme.sh with an own acme.sh home, so the sandbox's nginx installation is never touched.
#
# The DNS provider comes from the config (tls.dns_provider), the command stays the same:
#   manual   no DNS API on the node. Run 1 prints the _acme-challenge TXT records and stops;
#            add them in the DNS console; run 2 finishes. Renewals are manual (~60 days).
#   route53  fully automatic once the node has a Route 53 role (or tls.aws_* keys).
# See README.md in this directory for the steps, including staging first.
#
# Usage (as root on the k3s node that has kubectl):
#   ./oan-tls.sh <config.yaml> [--force]
#   --force   discard an open manual order and start a new one, or re-issue (e.g. staging ->
#             production, or manual -> route53). The TXT values change with every new order.
# Config: oan-tls.example.yaml.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../sandbox/lib"

# shellcheck source=../sandbox/lib/utils.sh
source "${LIB}/utils.sh"
# shellcheck source=../sandbox/lib/acme.sh
source "${LIB}/acme.sh"

# Own home, not the sandbox's /opt/acme.sh. The library reads these at call time.
ACME_HOME="/opt/acme-k8s"
ACME_CONFIG_HOME="${ACME_HOME}/data"
ACME_BIN="${ACME_HOME}/acme.sh"

CONFIG_FILE="${1:?usage: oan-tls.sh <config.yaml> [--force]}"
FORCE_MODE=false
[[ "${2:-}" == "--force" ]] && FORCE_MODE=true

check_root
load_config "$CONFIG_FILE"

domain="$(acme_domain)"
secret="$(cfg 'tls.k8s_secret' '')"
[[ -n "$secret" ]] || { log_error "tls.k8s_secret is not set" \
    "This script applies the certificate as a Secret, which needs <namespace>/<name>" \
    "Set tls.k8s_secret in ${CONFIG_FILE} (see oan-tls.example.yaml)"; exit 1; }

acme_preflight
acme_install_client

rc=0
# Apex first: acme.sh names its state directory after the first -d.
acme_issue_cert "$domain" "$domain" "*.${domain}" || rc=$?

if [[ $rc -eq 3 ]]; then
    exit 3   # waiting for the TXT records; the box above says what to add
elif [[ $rc -ne 0 ]]; then
    exit "$rc"
fi

log_success "Certificate for ${domain} and *.${domain} applied."
log_info "Check: kubectl -n ${secret%%/*} get secret ${secret#*/}"
log_info "Served by APISIX (replace <node IP>):"
log_info "  echo | openssl s_client -connect <node IP>:443 -servername a2c.${domain} 2>/dev/null | openssl x509 -noout -issuer -dates"
