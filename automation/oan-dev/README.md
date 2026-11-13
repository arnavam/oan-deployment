# OAN dev automation

Scripts for the OAN `oan_dev` k3s node that are not part of the OpenG2P sandbox. Kept in this fork so the
differences from upstream stay visible.

## `oan-k8s-tls.sh`

APISIX on `oan_dev` is the edge for `*.development.oanstaging.com`: it serves grievance and A2C itself and
passes every other host to the OpenG2P nginx/istio (oan-helm `environments/dev/values/oan-apisix-gateway.yaml`).
This script gives it the certificate: a Let's Encrypt wildcard (`development.oanstaging.com` and
`*.development.oanstaging.com`) from acme.sh over DNS-01 on Route 53, written to Secret
`oan-development-wildcard-tls` in `api6-gateway`. Renewals update the Secret by themselves. See the script header
for usage and the Route 53 permissions it needs.

It follows `automation/sandbox/lib/acme.sh` (same acme.sh version, CA and key type) but keeps its own home
(`/opt/acme-k8s`) and installs into a Secret instead of nginx files. The key is generated on the node, not copied
from the OpenG2P host's wildcard. DNS-01 works before Route 53 points at the node, so the gateway can be tested
with `curl --resolve` first.
