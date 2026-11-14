#!/usr/bin/env bash
# =============================================================================
# OpenG2P Sandbox — ACME (Let's Encrypt) + DNS provider helpers
# =============================================================================
# The sandbox uses REAL, publicly-trusted certificates from Let's Encrypt.
# Self-signed certs are not supported: in-cluster services call each other over
# HTTPS and fail when the issuing CA is not in the system trust store.
#
# Certificates are obtained with the ACME DNS-01 challenge:
#
#   node ──(1) write TXT _acme-challenge.<name>──▶ DNS provider API
#   node ──(2) "please issue <name>"─────────────▶ Let's Encrypt
#                            Let's Encrypt ──(3) DNS query──▶ DNS provider
#   node ◀──(4) signed certificate──────────────── Let's Encrypt
#
# Let's Encrypt never connects back to this machine, so NO inbound connectivity
# is required — only outbound HTTPS. That is what makes this work on-prem and
# behind NAT.
#
# No DNS API credential? tls.dns_provider: manual. Issuance then takes two runs
# of the same command with a person in between: run 1 prints the _acme-challenge
# TXT records and stops; you add them in the DNS console; run 2 waits until they
# are visible, completes the order and installs the certificate. Renewals are not
# automatic in this mode (see "Manual DNS" below).
#
# Install target: the sandbox writes files for nginx. With tls.k8s_secret set to
# <namespace>/<name>, every issue and renewal applies a kubernetes.io/tls Secret
# instead (APISIX on oan_dev, see automation/oan-dev/).
#
# ACME client: acme.sh. Chosen over certbot because it ships every DNS provider
# we support behind one uniform interface (`--dns dns_<x>` + env vars), is a
# single POSIX shell script with no Python/venv dependency, and persists both
# the DNS credentials and the nginx reload command so renewals are automatic.
#
# Sourced by roles/infra/run.sh (issuance) and by
# openg2p-sandbox.sh (laptop-side preflight). Depends only on cfg, log_*,
# curl and coreutils — deliberately no jq, so the laptop needs nothing extra.
# =============================================================================

# Pinned acme.sh release — bump deliberately, not automatically.
ACME_VERSION="3.1.4"
ACME_HOME="/opt/acme.sh"
ACME_CONFIG_HOME="/opt/acme.sh/data"
ACME_BIN="${ACME_HOME}/acme.sh"

# Where issued certs are installed. Kept identical to the previous layout so
# the Nginx templates and get_cert_path() are unchanged.
OPENG2P_CERTS_DIR="/etc/openg2p/certs"

DESEC_API="https://desec.io/api/v1"

# Reserved / special-use TLDs. A public CA can never issue for these — this is
# a CA/Browser Forum rule ("internal names"), not a Let's Encrypt policy.
ACME_RESERVED_TLDS="test local localhost internal invalid example home lan corp"

# ─────────────────────────────────────────────────────────────────────────────
# Domain helpers
# ─────────────────────────────────────────────────────────────────────────────
acme_domain() { cfg "domain" ""; }

# True when the domain ends in a TLD that can never receive a public cert.
acme_domain_is_reserved() {
    local domain="${1:-$(acme_domain)}"
    local tld="${domain##*.}"
    local reserved
    for reserved in $ACME_RESERVED_TLDS; do
        [[ "$tld" == "$reserved" ]] && return 0
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Provider plumbing
# ─────────────────────────────────────────────────────────────────────────────
# acme.sh DNS hook name for the configured provider.
acme_dns_hook() {
    case "$(cfg 'tls.dns_provider' 'desec')" in
        desec)      echo "dns_desec"   ;;
        cloudflare) echo "dns_cf"      ;;
        route53)    echo "dns_aws"     ;;
        acmedns)    echo "dns_acmedns" ;;
        manual)     echo "manual"      ;;
        *)          echo "" ;;
    esac
}

# Export the credential environment variables acme.sh expects for the provider.
# acme.sh persists these into its own config on first use, so renewals work
# without re-exporting.
acme_export_provider_creds() {
    local provider=$(cfg 'tls.dns_provider' 'desec')
    case "$provider" in
        desec)
            export DEDYN_TOKEN="$(cfg 'tls.api_token' '')"
            # Fail loudly on an empty token. acme.sh treats an empty env var
            # exactly like an unset one and silently falls back to whatever it
            # cached in account.conf on a previous run — which surfaces much
            # later as a bare "invalid domain" from the zone lookup.
            if [[ -z "$DEDYN_TOKEN" ]]; then
                log_error "tls.api_token is empty (dns_provider: desec)" \
                          "Without it the ACME client silently reuses a token cached from an earlier run" \
                          "Set tls.api_token in your config, then re-run" \
                          "grep -A5 '^tls:' <your-config>.yaml"
                return 1
            fi
            ;;
        cloudflare)
            export CF_Token="$(cfg 'tls.api_token' '')"
            export CF_Account_ID="$(cfg 'tls.cf_account_id' '')"
            ;;
        route53)
            # Blank credentials are valid: acme.sh falls back to the EC2
            # instance role, which is the common case on AWS.
            local ak=$(cfg 'tls.aws_access_key_id' '')
            local sk=$(cfg 'tls.aws_secret_access_key' '')
            [[ -n "$ak" ]] && export AWS_ACCESS_KEY_ID="$ak"
            [[ -n "$sk" ]] && export AWS_SECRET_ACCESS_KEY="$sk"
            ;;
        acmedns)
            export ACMEDNS_BASE_URL="$(cfg 'tls.acmedns_base_url' 'https://auth.acme-dns.io')"
            export ACMEDNS_USERNAME="$(cfg 'tls.acmedns_username' '')"
            export ACMEDNS_PASSWORD="$(cfg 'tls.acmedns_password' '')"
            export ACMEDNS_SUBDOMAIN="$(cfg 'tls.acmedns_subdomain' '')"
            ;;
        manual)
            # No credentials: the person adds the TXT records.
            ;;
        *)
            log_error "Unknown tls.dns_provider: '${provider}'" \
                      "Valid values: desec, cloudflare, route53, acmedns, manual" \
                      "Fix tls.dns_provider in your config file"
            return 1
            ;;
    esac
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight — validate DNS/TLS prerequisites BEFORE anything is installed
# ─────────────────────────────────────────────────────────────────────────────
# Runs on the laptop (orchestrator) and again on-box. Fails fast and loudly:
# a wrong token here would otherwise surface 20 minutes into the install.
acme_preflight() {
    local domain=$(acme_domain)
    local email=$(cfg 'tls.email' '')
    local provider=$(cfg 'tls.dns_provider' 'desec')
    local errors=0

    log_info "Validating DNS / TLS prerequisites..."

    # ── Domain ───────────────────────────────────────────────────────────
    if [[ -z "$domain" ]]; then
        log_error "'domain' is not set" \
                  "The sandbox needs a REAL registered domain for Let's Encrypt to certify" \
                  "Get a free one in ~2 min: sign up at https://desec.io/, create e.g. mydept.dedyn.io, then set 'domain' in your config" \
                  "" \
                  "https://desec.io/"
        return 1
    fi

    if acme_domain_is_reserved "$domain"; then
        log_error "'domain' uses a reserved TLD: ${domain}" \
                  "No public CA can ever issue a certificate for .${domain##*.} — this is a CA/Browser Forum rule, not a Let's Encrypt limitation" \
                  "Use a real registered domain. Free option: sign up at https://desec.io/ and create <name>.dedyn.io" \
                  "" \
                  "https://desec.io/"
        return 1
    fi

    if [[ "$domain" != *.* ]]; then
        log_error "'domain' does not look like a domain name: ${domain}" \
                  "Expected something like mydept.dedyn.io" \
                  "Fix 'domain' in your config file"
        return 1
    fi
    log_success "Domain: ${domain}"

    # ── Let's Encrypt account email ──────────────────────────────────────
    if [[ -z "$email" ]]; then
        log_error "'tls.email' is not set" \
                  "Let's Encrypt requires a contact address for expiry notices" \
                  "Set tls.email in your config file"
        ((errors++))
    elif [[ ! "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        log_error "'tls.email' is not a valid email address: ${email}" \
                  "Let's Encrypt will reject the account registration" \
                  "Fix tls.email in your config file"
        ((errors++))
    fi

    # ── Provider credentials ─────────────────────────────────────────────
    case "$provider" in
        desec)
            if [[ -z "$(cfg 'tls.api_token' '')" ]]; then
                log_error "'tls.api_token' is not set (dns_provider: desec)" \
                          "A deSEC API token is required to write the ACME challenge record" \
                          "Create one at https://desec.io/tokens and set tls.api_token" \
                          "" \
                          "https://desec.io/tokens"
                ((errors++))
            fi
            ;;
        cloudflare)
            [[ -z "$(cfg 'tls.api_token' '')" ]] && {
                log_error "'tls.api_token' is not set (dns_provider: cloudflare)" \
                          "A Cloudflare API token with DNS:Edit on the zone is required" \
                          "Create a scoped token and set tls.api_token"
                ((errors++)); }
            ;;
        route53)
            if [[ -z "$(cfg 'tls.aws_access_key_id' '')" ]]; then
                log_info "  route53: no static keys set — will use the EC2 instance role."
            fi
            ;;
        acmedns)
            [[ -z "$(cfg 'tls.acmedns_username' '')" ]] && {
                log_error "acme-dns credentials incomplete (dns_provider: acmedns)" \
                          "tls.acmedns_username / acmedns_password / acmedns_subdomain are required" \
                          "Register with your acme-dns server and fill in the tls.acmedns_* fields"
                ((errors++)); }
            ;;
        manual)
            log_info "  manual: no DNS API. Issuance stops once so you can add the TXT records; re-run to finish."
            log_warn "  manual: renewals are NOT automatic. Re-run after about 60 days (certificates last 90)."
            ;;
        *)
            log_error "Unknown tls.dns_provider: '${provider}'" \
                      "Valid values: desec, cloudflare, route53, acmedns, manual" \
                      "Fix tls.dns_provider in your config file"
            ((errors++))
            ;;
    esac

    # ── Kubernetes Secret target (optional) ──────────────────────────────
    local k8s_secret=$(cfg 'tls.k8s_secret' '')
    if [[ -n "$k8s_secret" && ! "$k8s_secret" =~ ^[a-z0-9.-]+/[a-z0-9.-]+$ ]]; then
        log_error "'tls.k8s_secret' must be <namespace>/<name>: ${k8s_secret}" \
                  "The certificate is applied as a kubernetes.io/tls Secret with that name" \
                  "Set tls.k8s_secret to e.g. api6-gateway/oan-development-wildcard-tls, or remove it for nginx files"
        ((errors++))
    fi

    [[ $errors -gt 0 ]] && return 1

    # ── Live credential check (deSEC only — it is the quick-start path) ──
    if [[ "$provider" == "desec" ]]; then
        acme_preflight_desec "$domain" || return 1
    elif [[ "$provider" == "manual" ]]; then
        :   # nothing to verify: there is no credential
    else
        log_warn "Credentials for '${provider}' are not verified live — a wrong token will surface during issuance."
    fi

    # ── Staging notice ───────────────────────────────────────────────────
    if [[ "$(cfg 'tls.staging' 'false')" == "true" ]]; then
        log_warn "tls.staging is TRUE — certificates will come from the Let's Encrypt STAGING CA."
        log_warn "  These are NOT publicly trusted. Browsers and in-cluster services will still warn/fail."
        log_warn "  Set tls.staging: false and re-run with --force for real certificates."
    fi

    log_success "DNS / TLS prerequisites satisfied."
    return 0
}

# Verify the deSEC token works AND the domain exists in that account.
# This is the single highest-value check: it catches the two mistakes users
# actually make (typo'd token, domain never created).
acme_preflight_desec() {
    local domain="$1"
    local token=$(cfg 'tls.api_token' '')

    if ! command -v curl >/dev/null 2>&1; then
        log_warn "curl not available — skipping the live deSEC check."
        return 0
    fi

    log_info "  Verifying deSEC token and domain '${domain}'..."

    local body http_code
    body=$(curl -sS --max-time 20 -w '\n%{http_code}' \
        -H "Authorization: Token ${token}" \
        "${DESEC_API}/domains/${domain}/" 2>/dev/null) || {
        log_error "Could not reach the deSEC API" \
                  "No network path to ${DESEC_API} from this machine" \
                  "Check outbound HTTPS/internet access, then re-run" \
                  "curl -sS ${DESEC_API}/domains/"
        return 1
    }
    http_code=$(echo "$body" | tail -1)

    case "$http_code" in
        200)
            log_success "  deSEC token valid; domain '${domain}' found."
            # acme.sh's deSEC plugin detects the zone by LISTING all domains
            # (GET /domains/) and string-matching the name — a different
            # permission from the single-domain read above. A token restricted
            # by deSEC token policies can pass the read and still fail the
            # list, which surfaces much later as a bare "invalid domain".
            # Check it here instead.
            local list_body list_code
            list_body=$(curl -sS --max-time 20 -w '\n%{http_code}' \
                -H "Authorization: Token ${token}" \
                "${DESEC_API}/domains/" 2>/dev/null) || {
                log_warn "  Could not list deSEC domains — skipping the zone-detection check."
                return 0
            }
            list_code=$(echo "$list_body" | tail -1)
            if [[ "$list_code" != "200" ]] || ! echo "$list_body" | sed '$d' | grep -q "\"name\": *\"${domain}\""; then
                log_error "deSEC token cannot LIST domains (HTTP ${list_code})" \
                          "The token reads '${domain}' fine, but the ACME client detects the zone via GET ${DESEC_API}/domains/ and that call does not return it" \
                          "This is usually a token restricted by deSEC token policies. Create an UNRESTRICTED token at https://desec.io/tokens and set tls.api_token to it" \
                          "curl -s -H 'Authorization: Token <token>' ${DESEC_API}/domains/" \
                          "https://desec.io/tokens"
                return 1
            fi
            log_success "  deSEC token can list domains (zone detection will work)."
            return 0
            ;;
        401|403)
            log_error "deSEC rejected the API token (HTTP ${http_code})" \
                      "tls.api_token is wrong, expired, or lacks permission" \
                      "Create a fresh token at https://desec.io/tokens and update tls.api_token" \
                      "" \
                      "https://desec.io/tokens"
            return 1
            ;;
        404)
            log_error "Domain '${domain}' does not exist in your deSEC account" \
                      "The token is valid, but no such domain is registered to it" \
                      "Create the domain at https://desec.io/domains (it must match 'domain' exactly), then re-run" \
                      "" \
                      "https://desec.io/domains"
            return 1
            ;;
        *)
            log_error "Unexpected response from deSEC (HTTP ${http_code})" \
                      "Could not confirm the token/domain are usable" \
                      "Check https://desec.io/ status and your config, then re-run"
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Publish A records so hostnames resolve without any local DNS server
# ─────────────────────────────────────────────────────────────────────────────
# Usage: acme_publish_a_record <subname> <ip>
#   subname is relative to `domain`, e.g. "rancher" or "*.dev" ("" = apex).
#
# Only implemented for deSEC (the quick-start path). For cloudflare/route53/
# acmedns the operator already runs their own DNS, so we print exactly what to
# create rather than pretending to manage their zone.
acme_publish_a_record() {
    local subname="$1"
    local ip="$2"
    local domain=$(acme_domain)
    local provider=$(cfg 'tls.dns_provider' 'desec')

    if [[ "$(cfg 'tls.publish_a_records' 'true')" != "true" ]]; then
        log_info "tls.publish_a_records is false — skipping A record for ${subname:-@}.${domain}"
        return 0
    fi

    local fqdn="${subname:+${subname}.}${domain}"

    if [[ "$provider" != "desec" ]]; then
        log_warn "A-record publishing is automated for deSEC only."
        log_warn "  Create this record in your '${provider}' zone manually:"
        log_warn "      ${fqdn}   A   ${ip}"
        return 0
    fi

    local token=$(cfg 'tls.api_token' '')
    log_info "Publishing DNS A record: ${fqdn} -> ${ip}"

    # Bulk endpoint: upserts, and avoids URL-encoding '*' into a path segment.
    local payload http_code body
    payload=$(printf '[{"subname":"%s","type":"A","ttl":3600,"records":["%s"]}]' "$subname" "$ip")

    body=$(curl -sS --max-time 30 -w '\n%{http_code}' -X PUT \
        -H "Authorization: Token ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${DESEC_API}/domains/${domain}/rrsets/" 2>/dev/null) || {
        log_error "Failed to reach the deSEC API while publishing ${fqdn}" \
                  "Network error talking to ${DESEC_API}" \
                  "Check outbound internet access and re-run this phase"
        return 1
    }
    http_code=$(echo "$body" | tail -1)

    if [[ "$http_code" =~ ^2 ]]; then
        log_success "DNS: ${fqdn} -> ${ip} (TTL 3600)"
        return 0
    fi

    log_error "deSEC rejected the A record for ${fqdn} (HTTP ${http_code})" \
              "Response: $(echo "$body" | sed '$d' | head -c 300)" \
              "Verify tls.api_token has write access to '${domain}', then re-run" \
              "" \
              "https://desec.io/domains"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Wait for a freshly published name to be visible in PUBLIC DNS
# ─────────────────────────────────────────────────────────────────────────────
# Publishing an RRset and immediately asking Let's Encrypt to validate is a
# race. If any resolver queried the name while it did not exist, it cached the
# NXDOMAIN for the zone's negative TTL (deSEC: up to 3600s) — and per RFC 8020
# that also suppresses every name BELOW it, including _acme-challenge.<name>.
# Let's Encrypt validates from several vantage points with its own resolvers,
# so one stale cache is enough to fail the order.
#
# Failed validations also count against Let's Encrypt's rate limits, so it is
# worth confirming visibility before spending an attempt.
#
# Usage: acme_wait_dns_propagation <fqdn> [timeout_seconds]
acme_wait_dns_propagation() {
    local fqdn="$1"
    local timeout="${2:-900}"

    if ! command -v dig >/dev/null 2>&1; then
        log_warn "dig not available — skipping the DNS propagation check for ${fqdn}."
        return 0
    fi

    log_info "Waiting for ${fqdn} to be visible in public DNS..."

    # Public resolvers with independent caches. All must stop saying NXDOMAIN
    # before we ask Let's Encrypt to validate.
    local resolvers="1.1.1.1 8.8.8.8 9.9.9.9"
    local elapsed=0 interval=15

    while [[ $elapsed -lt $timeout ]]; do
        local all_ok=true r status
        for r in $resolvers; do
            # A dig timeout prints no "status:" line; without `|| true`,
            # grep's non-zero exit trips `set -eo pipefail` and silently
            # aborts the whole run instead of retrying.
            status=$(dig "@${r}" +noall +comments +time=5 +tries=1 A "$fqdn" 2>/dev/null \
                     | grep -o "status: [A-Z]*" | head -1 | awk '{print $2}') || true
            # NOERROR means the name exists (with or without an A record).
            # NXDOMAIN means a resolver still has the negative answer cached.
            if [[ "$status" != "NOERROR" ]]; then
                all_ok=false
                break
            fi
        done

        if [[ "$all_ok" == "true" ]]; then
            log_success "${fqdn} is visible in public DNS."
            return 0
        fi

        [[ $elapsed -eq 0 ]] && log_info "  A resolver still has a stale NXDOMAIN cached; waiting (up to ${timeout}s)..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_warn "${fqdn} is still not consistently visible after ${timeout}s."
    log_warn "  Proceeding anyway — validation may fail if a Let's Encrypt resolver"
    log_warn "  still holds a cached NXDOMAIN. If it does, wait for the zone's"
    log_warn "  negative TTL to expire (dig SOA ${fqdn#*.} — last field) and re-run."
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# acme.sh installation
# ─────────────────────────────────────────────────────────────────────────────
acme_install_client() {
    if [[ -x "$ACME_BIN" ]]; then
        log_success "acme.sh already installed at ${ACME_BIN}."
        return 0
    fi

    log_info "Installing acme.sh ${ACME_VERSION}..."

    # acme.sh refuses to install without crontab (it registers the renewal
    # job there). Ubuntu minimal/cloud images often ship without cron.
    if ! command -v crontab >/dev/null 2>&1; then
        log_info "Installing cron (required by acme.sh for auto-renewal)..."
        apt-get install -y -qq cron > /dev/null 2>&1 || {
            log_error "Failed to install cron" \
                      "acme.sh needs crontab to schedule certificate renewal" \
                      "Install it manually: apt-get install -y cron"
            return 1
        }
        systemctl enable --now cron > /dev/null 2>&1 || true
    fi

    local tarball="/tmp/acme.sh-${ACME_VERSION}.tar.gz"
    local srcdir="/tmp/acme.sh-${ACME_VERSION}"
    rm -rf "$srcdir"

    curl -fsSL -o "$tarball" \
        "https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz" || {
        log_error "Failed to download acme.sh ${ACME_VERSION}" \
                  "Could not fetch the release tarball from GitHub" \
                  "Check outbound internet access, then re-run" \
                  "curl -fsSL https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz -o /tmp/acme.tar.gz"
        return 1
    }

    tar -xzf "$tarball" -C /tmp || {
        log_error "Failed to extract the acme.sh tarball" "" "Re-run to retry"
        return 1
    }

    ( cd "$srcdir" && ./acme.sh --install \
        --home "$ACME_HOME" \
        --config-home "$ACME_CONFIG_HOME" \
        --cert-home "${ACME_HOME}/certs" \
        -m "$(cfg 'tls.email' '')" \
        --no-profile > /dev/null 2>&1 ) || {
        log_error "acme.sh installation failed" \
                  "The installer returned a non-zero status" \
                  "Try manually: cd ${srcdir} && ./acme.sh --install --home ${ACME_HOME}"
        return 1
    }

    rm -rf "$tarball" "$srcdir"

    # acme.sh defaults to ZeroSSL — pin the default CA to Let's Encrypt.
    "$ACME_BIN" --set-default-ca --server letsencrypt \
        --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" > /dev/null 2>&1 || true

    # Drop any DNS credential cached by an earlier run. The config file is the
    # single source of truth; a stale cached token would otherwise win whenever
    # the env var is empty and fail confusingly during the zone lookup.
    if [[ -f "${ACME_CONFIG_HOME}/account.conf" ]]; then
        sed -i '/^SAVED_DEDYN_TOKEN=/d;/^SAVED_CF_Token=/d;/^SAVED_CF_Account_ID=/d;/^SAVED_AWS_ACCESS_KEY_ID=/d;/^SAVED_AWS_SECRET_ACCESS_KEY=/d' \
            "${ACME_CONFIG_HOME}/account.conf" 2>/dev/null || true
    fi

    # Credentials land in account.conf; acme.sh sets 600/700 at creation, but
    # tighten defensively in case the directories pre-existed.
    chown -R root:root "$ACME_HOME" 2>/dev/null || true
    chmod 700 "$ACME_HOME" "$ACME_CONFIG_HOME" 2>/dev/null || true
    chmod 600 "${ACME_CONFIG_HOME}/account.conf" 2>/dev/null || true

    log_success "acme.sh ${ACME_VERSION} installed (auto-renewal cron registered)."
}

# ─────────────────────────────────────────────────────────────────────────────
# Certificate issuance
# ─────────────────────────────────────────────────────────────────────────────
# Usage: acme_issue_cert <install_name> <primary_fqdn> [additional_fqdn ...]
#
#   install_name  directory under /etc/openg2p/certs/ to install into. Callers
#                 pass the hostname (infra) or base domain (environment) so
#                 get_cert_path() keeps working unchanged.
#   primary_fqdn  MUST be a non-wildcard name — acme.sh names its internal
#                 state directory after the first -d, and a literal '*' in a
#                 path is a persistent nuisance.
#
# Idempotent: acme.sh skips re-issuance while the cert is still fresh, unless
# FORCE_MODE is set.
acme_issue_cert() {
    local install_name="$1"; shift
    local primary="$1"
    local dest="${OPENG2P_CERTS_DIR}/${install_name}"

    if [[ -z "$primary" ]]; then
        log_error "acme_issue_cert called without a domain" "" "This is a bug in the automation"
        return 1
    fi

    acme_export_provider_creds || return 1

    local hook=$(acme_dns_hook)
    if [[ -z "$hook" ]]; then
        log_error "No acme.sh DNS hook for provider '$(cfg 'tls.dns_provider' 'desec')'" \
                  "" "Fix tls.dns_provider in your config file"
        return 1
    fi

    # Build -d args
    local -a domain_args=()
    local d
    for d in "$@"; do
        domain_args+=(-d "$d")
    done

    local -a extra_args=()
    [[ "$(cfg 'tls.staging' 'false')" == "true" ]] && extra_args+=(--staging)
    [[ "${FORCE_MODE:-false}" == "true" ]] && extra_args+=(--force)

    # Settling time between writing the _acme-challenge TXT and letting
    # Let's Encrypt validate.
    #
    # By default acme.sh polls public DNS-over-HTTPS and proceeds as soon as
    # ONE resolver sees the record. That has proved optimistic here: the DoH
    # check passed while Let's Encrypt — validating from several vantage
    # points, against both deSEC nameservers — still reported "No TXT record
    # found" ~24s after the write. --dnssleep replaces that check with a flat
    # wait, which is slower but far more reliable on a freshly created name.
    # deSEC's ns2.desec.org has been measured serving a new TXT ~100s after
    # ns1, and Let's Encrypt may query a further-away anycast node, so 120s is
    # not enough margin.
    #
    # Set tls.dns_propagation_seconds: 0 to restore acme.sh's adaptive check.
    local dns_sleep
    dns_sleep=$(cfg 'tls.dns_propagation_seconds' '300')
    if [[ "$dns_sleep" != "0" && "$hook" != "manual" ]]; then
        extra_args+=(--dnssleep "$dns_sleep")
        log_info "  Allowing ${dns_sleep}s for DNS propagation before validation."
    fi

    log_info "Requesting certificate for: $*"
    log_info "  (DNS-01 via ${hook} — outbound only, no inbound connectivity needed)"

    # The calling script already redirects stdout/stderr through tee, so
    # acme.sh's progress lands in the log without piping here (which would
    # otherwise mask its exit status behind tee's).
    local rc=0
    if [[ "$hook" == "manual" ]]; then
        acme_issue_manual "$primary" "${domain_args[@]}" "${extra_args[@]}" || rc=$?
        # 3 == the TXT records are not in DNS yet; the person has been told what to add.
        [[ $rc -eq 3 ]] && return 3
    else
        "$ACME_BIN" --issue \
            --dns "$hook" \
            "${domain_args[@]}" \
            --server letsencrypt \
            --keylength ec-256 \
            --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" \
            "${extra_args[@]}" || rc=$?
    fi

    # rc 2 == "skipped, cert still valid" — treat as success.
    if [[ $rc -ne 0 && $rc -ne 2 ]]; then
        log_error "Certificate issuance failed for ${primary}" \
                  "acme.sh exited with status ${rc}" \
                  "If the output above says 'No TXT record found' or 'secondary validation', a Let's Encrypt resolver has a stale negative (NXDOMAIN) answer cached: wait for the zone's negative TTL to expire (dig SOA ${primary#*.} — last field, 3600s on deSEC) and re-run; already-validated names are reused. Otherwise check the DNS API token, that the domain is in that DNS account, and outbound internet access." \
                  "${ACME_BIN} --issue --dns ${hook} -d ${primary} --server letsencrypt --home ${ACME_HOME} --config-home ${ACME_CONFIG_HOME} --debug"
        return 1
    fi

    # Install into the stable path the Nginx config reads, and register the
    # reload command. acme.sh persists the reloadcmd, so every future renewal
    # re-installs here and reloads Nginx (or re-applies the Secret) automatically.
    local reload_cmd
    reload_cmd=$(acme_reload_cmd "$dest") || return 1
    mkdir -p "$dest"
    "$ACME_BIN" --install-cert -d "$primary" --ecc \
        --key-file       "${dest}/privkey.pem" \
        --fullchain-file "${dest}/fullchain.pem" \
        --reloadcmd      "$reload_cmd" \
        --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" > /dev/null 2>&1 || {
        log_error "Failed to install the issued certificate to ${dest}" \
                  "acme.sh --install-cert returned an error, or its reload command failed (with tls.k8s_secret: kubectl could not apply the Secret, e.g. the namespace does not exist)" \
                  "Check ${ACME_HOME}/certs/${primary}_ecc/ for the issued files"
        return 1
    }

    chmod 600 "${dest}/privkey.pem" 2>/dev/null || true
    log_success "Certificate installed: ${dest}/fullchain.pem"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Reload command: nginx for the sandbox, a TLS Secret when tls.k8s_secret is set
# ─────────────────────────────────────────────────────────────────────────────
# Usage: acme_reload_cmd <dest>   (prints the command acme.sh runs after every
# issue and renewal; <dest> holds the fullchain.pem and privkey.pem it just wrote)
acme_reload_cmd() {
    local dest="$1"
    local secret=$(cfg 'tls.k8s_secret' '')

    if [[ -z "$secret" ]]; then
        echo "systemctl reload nginx 2>/dev/null || true"
        return 0
    fi

    local ns="${secret%%/*}" name="${secret#*/}"
    local kubeconfig=$(cfg 'tls.kubeconfig' '/etc/rancher/k3s/k3s.yaml')

    # cron runs with a short PATH, so resolve kubectl now.
    local kubectl_bin
    kubectl_bin=$(command -v kubectl) || {
        log_error "kubectl not found (tls.k8s_secret: ${secret})" \
                  "The certificate is applied as a Secret with kubectl, which must be on this machine" \
                  "Run this on a node with kubectl, or remove tls.k8s_secret to write nginx files"
        return 1
    }

    echo "KUBECONFIG='${kubeconfig}' '${kubectl_bin}' -n '${ns}' create secret tls '${name}' --cert='${dest}/fullchain.pem' --key='${dest}/privkey.pem' --dry-run=client -o yaml | KUBECONFIG='${kubeconfig}' '${kubectl_bin}' apply -f -"
}

# ─────────────────────────────────────────────────────────────────────────────
# Manual DNS (tls.dns_provider: manual) — a zone no API credential reaches
# ─────────────────────────────────────────────────────────────────────────────
# Two runs of the same command, with a person in between:
#
#   run 1  asks Let's Encrypt for the order and prints the _acme-challenge TXT
#          records. The step stops (acme_issue_cert returns 3).
#   you    add the records in the DNS console.
#   run 2  waits until the records are visible on public resolvers (a failed
#          validation counts against Let's Encrypt's rate limits), completes the
#          order with `acme.sh --renew` and installs the certificate.
#
# Renewals are NOT automatic: acme.sh's cron cannot add the records. Run the same
# command again after about 60 days; the certificate lasts 90.
#
# Between the runs the file ${ACME_CONFIG_HOME}/manual-pending-<name> records the
# names of the open order. Run with --force (FORCE_MODE) to discard it and start a
# new order, e.g. when switching from staging to production: the TXT values change.
# To move to an API provider, set tls.dns_provider and run with --force.

acme_manual_marker() { echo "${ACME_CONFIG_HOME}/manual-pending-${1}"; }

# "<count> <challenge name>" per distinct challenge name. The apex and its wildcard
# share one name, so that name needs TWO TXT values.
acme_manual_challenges() {
    local name
    for name in "$@"; do
        echo "_acme-challenge.${name#\*.}"
    done | sort | uniq -c | sed 's/^ *//'
}

# Wait until every challenge name shows all its TXT values on three public
# resolvers. Returns 1 on timeout (tls.dns_propagation_seconds, default 300).
acme_manual_wait_txt() {
    local timeout
    timeout=$(cfg 'tls.dns_propagation_seconds' '300')
    [[ "$timeout" == "0" ]] && return 0

    if ! command -v dig >/dev/null 2>&1; then
        log_warn "dig not available — not checking that the TXT records are visible."
        return 0
    fi

    log_info "Waiting for the TXT records to be visible in public DNS (up to ${timeout}s)..."
    local elapsed=0 interval=15 all_ok count name r n
    while :; do
        all_ok=true
        while read -r count name; do
            for r in 1.1.1.1 8.8.8.8 9.9.9.9; do
                # grep -c prints 0 and exits 1 when nothing matches.
                n=$(dig "@${r}" +short +time=5 +tries=1 TXT "$name" 2>/dev/null | grep -c .) || true
                if [[ "${n:-0}" -lt "$count" ]]; then
                    all_ok=false
                    break
                fi
            done
            $all_ok || break
        done < <(acme_manual_challenges "$@")

        if $all_ok; then
            log_success "The TXT records are visible."
            return 0
        fi
        [[ $elapsed -ge $timeout ]] && break
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    return 1
}

# Usage: acme_issue_manual <primary_fqdn> <acme.sh args: -d <name>... [--staging] [--force]>
# Returns 0 issued (or still valid), 2 still valid, 3 waiting for the TXT records, 1 error.
acme_issue_manual() {
    local primary="$1"; shift
    local -a acme_args=("$@")
    local marker
    marker=$(acme_manual_marker "$primary")
    local manual_flag="--yes-I-know-dns-manual-mode-enough-go-ahead-please"

    local -a names=()
    local arg prev=""
    for arg in "${acme_args[@]}"; do
        [[ "$prev" == "-d" ]] && names+=("$arg")
        prev="$arg"
    done

    if [[ "${FORCE_MODE:-false}" == "true" && -f "$marker" ]]; then
        log_info "--force: discarding the open order for ${primary} and starting a new one."
        rm -f "$marker"
    fi

    local rc=0

    # ── Run 2: the records should be in DNS now ──────────────────────────
    if [[ -f "$marker" ]]; then
        log_info "Open manual DNS order for ${primary} — completing it."
        if ! acme_manual_wait_txt "${names[@]}"; then
            log_manual_action "The TXT records for ${primary} are not visible in public DNS yet." \
                              "Expected: $(acme_manual_challenges "${names[@]}" | awk '{printf "%s (%s value%s)  ", $2, $1, ($1 > 1 ? "s" : "")}')" \
                              "Check the name and every value, give DNS a few minutes. To start over with new values run with --force."
            return 3
        fi

        "$ACME_BIN" --renew -d "$primary" --ecc "$manual_flag" \
            --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" || rc=$?
        if [[ $rc -ne 0 ]]; then
            # Keep the marker: the records may only need more time.
            log_error "Let's Encrypt did not validate the TXT records for ${primary}" \
                      "A value is missing or wrong, or a resolver still serves an old answer. The values change with every new order, so records from an earlier order (e.g. staging) do not match" \
                      "Compare the values in DNS with the ones printed by the first run; to start over run with --force and add the new values" \
                      "dig +short TXT _acme-challenge.${primary#\*.} @8.8.8.8"
            return 1
        fi
        rm -f "$marker"
        return 0
    fi

    # ── Run 1: open the order and print the records ──────────────────────
    local out
    out=$(mktemp)
    "$ACME_BIN" --issue --dns "$manual_flag" \
        "${acme_args[@]}" \
        --server letsencrypt \
        --keylength ec-256 \
        --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" > "$out" 2>&1 || rc=$?
    cat "$out"

    # acme.sh lists the records to add and exits non-zero; that is the normal outcome here.
    if grep -Eq 'TXT value|_acme-challenge' "$out"; then
        rm -f "$out"
        printf '%s\n' "${names[@]}" > "$marker"
        log_manual_action "Add the DNS TXT records printed above for ${primary}." \
                          "Names: $(acme_manual_challenges "${names[@]}" | awk '{printf "%s (%s value%s)  ", $2, $1, ($1 > 1 ? "s" : "")}')" \
                          "Several values on one name go into ONE TXT record set (Route 53 requires it)."
        return 3
    fi

    rm -f "$out"
    return "$rc"
}
