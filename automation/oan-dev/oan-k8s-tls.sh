#!/usr/bin/env bash
# =============================================================================
# OAN dev — Let's Encrypt certificates as Kubernetes TLS Secrets (acme.sh, DNS-01)
# =============================================================================
# Issues a certificate per target with acme.sh over DNS-01 on Route 53 and keeps the
# Kubernetes Secret APISIX serves (ApisixTls `secret`) up to date. The private key is
# generated on this node and only ever lives here and in the Secret: it is not copied from
# another host's wildcard. DNS-01 needs no inbound port, so it works before the Route 53
# records point at this node.
#
# Same client, version, CA and key type as automation/sandbox/lib/acme.sh. Differences:
# its own home (/opt/acme-k8s) so it never touches the nginx installation, and the install
# step applies a Secret instead of writing nginx files. acme.sh remembers the install
# command, so its cron renewals refresh the Secrets without this script.
#
# Usage (as root on the k3s node that has kubectl):
#   KUBECONFIG=/etc/rancher/k3s/k3s.yaml ACME_EMAIL=ops@example.org ./oan-k8s-tls.sh issue
#   ACME_STAGING=1 ... ./oan-k8s-tls.sh issue      # Let's Encrypt staging, to test first
#   ... ./oan-k8s-tls.sh apply <ns> <secret> <fullchain.pem> <privkey.pem>   # used by acme.sh
#
# Environment:
#   ACME_EMAIL     required for `issue`: the Let's Encrypt account contact
#   KUBECONFIG     required: kubeconfig acme.sh's renewals use (also stored in the install command)
#   TLS_TARGETS    space-separated `namespace:secret:host`; default below
#   ACME_STAGING   1 = staging CA (certificates are not trusted)
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   optional: without them acme.sh uses the EC2
#                  instance role. Needs route53:ListHostedZones, route53:GetChange and
#                  route53:ChangeResourceRecordSets on the zone. acme.sh keeps keys it is
#                  given in /opt/acme-k8s/data/account.conf (0600).
# =============================================================================
set -euo pipefail

ACME_VERSION="3.1.4"
ACME_HOME="/opt/acme-k8s"
ACME_CONFIG_HOME="${ACME_HOME}/data"
ACME_BIN="${ACME_HOME}/acme.sh"
INSTALLED_SCRIPT="${ACME_HOME}/oan-k8s-tls.sh"
DEFAULT_TARGETS="grievance:oan-grievance-tls:grievance-service.development.oanstaging.com a2c:oan-a2c-tls:a2c-service.development.oanstaging.com"

log() { echo "[oan-k8s-tls] $*"; }
die() { echo "[oan-k8s-tls] ERROR: $*" >&2; exit 1; }

install_client() {
	[[ -x "$ACME_BIN" ]] && return
	command -v crontab >/dev/null || die "crontab is missing: acme.sh registers its renewal job there (apt-get install -y cron)"
	log "Installing acme.sh ${ACME_VERSION} into ${ACME_HOME}"
	local tmp
	tmp="$(mktemp -d)"
	curl -fsSL "https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz" | tar -xz -C "$tmp"
	(cd "$tmp/acme.sh-${ACME_VERSION}" && ./acme.sh --install --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" \
		--cert-home "${ACME_HOME}/certs" -m "$ACME_EMAIL" --no-profile >/dev/null)
	rm -rf "$tmp"
	chmod 700 "$ACME_HOME" "$ACME_CONFIG_HOME"
}

# Called by acme.sh after every issue and renewal.
apply_secret() {
	local ns="$1" name="$2" cert="$3" key="$4"
	kubectl -n "$ns" create secret tls "$name" --cert="$cert" --key="$key" --dry-run=client -o yaml | kubectl apply -f -
}

issue() {
	[[ -n "${ACME_EMAIL:-}" ]] || die "Set ACME_EMAIL"
	[[ -n "${KUBECONFIG:-}" ]] || die "Set KUBECONFIG"
	command -v kubectl >/dev/null || die "kubectl is not installed"
	install_client
	# Renewals run the installed copy, so they do not depend on a repository checkout.
	install -m 0700 "$0" "$INSTALLED_SCRIPT"

	local ca=letsencrypt
	[[ "${ACME_STAGING:-0}" == 1 ]] && ca=letsencrypt_test
	"$ACME_BIN" --set-default-ca --server "$ca" --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" >/dev/null

	local target ns secret host
	for target in ${TLS_TARGETS:-$DEFAULT_TARGETS}; do
		IFS=: read -r ns secret host <<<"$target"
		[[ -n "$ns" && -n "$secret" && -n "$host" ]] || die "Bad target '${target}', expected namespace:secret:host"
		log "Issuing ${host} -> ${ns}/${secret} (${ca})"
		# rc 2 = still valid, nothing to do.
		"$ACME_BIN" --issue --dns dns_aws -d "$host" --server "$ca" --keylength ec-256 \
			--home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" || [[ $? -eq 2 ]]
		"$ACME_BIN" --install-cert -d "$host" --ecc \
			--key-file "${ACME_HOME}/certs/${host}.key" --fullchain-file "${ACME_HOME}/certs/${host}.fullchain.pem" \
			--reloadcmd "KUBECONFIG=${KUBECONFIG} ${INSTALLED_SCRIPT} apply ${ns} ${secret} ${ACME_HOME}/certs/${host}.fullchain.pem ${ACME_HOME}/certs/${host}.key" \
			--home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME"
	done
	log "Done. Check: kubectl get secret -A | grep -E 'oan-(grievance|a2c)-tls'"
}

case "${1:-}" in
	issue) issue ;;
	apply) shift; apply_secret "$@" ;;
	*) die "Usage: oan-k8s-tls.sh issue | apply <ns> <secret> <fullchain.pem> <privkey.pem> (see the header)" ;;
esac
