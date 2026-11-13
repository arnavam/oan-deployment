# OAN dev automation

Scripts for the OAN `oan_dev` k3s node that are not part of the OpenG2P sandbox. Kept in this fork so the
differences from upstream stay visible.

## `oan-k8s-tls.sh`

Issues Let's Encrypt certificates with acme.sh (DNS-01, Route 53) and writes them to the Kubernetes Secrets
that APISIX serves: `oan-grievance-tls` in `grievance` and `oan-a2c-tls` in `a2c`. Renewals update the
Secrets by themselves. See the script header for usage and the Route 53 permissions it needs.

It follows `automation/sandbox/lib/acme.sh` (same acme.sh version, CA and key type) but keeps its own home
(`/opt/acme-k8s`) and installs into a Secret instead of nginx files. The key is generated on the node, not
copied from the `*.development.oanstaging.com` wildcard on the nginx host.
