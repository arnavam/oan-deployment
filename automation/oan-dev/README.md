# OAN dev automation

Scripts for the OAN `oan_dev` k3s node that are not part of the OpenG2P sandbox. Kept in this fork so the
differences from upstream stay visible.

APISIX on `oan_dev` is the edge for `*.development.oanstaging.com`: it serves grievance and A2C itself and
passes every other host to the OpenG2P nginx/istio (oan-helm `environments/dev/values/oan-apisix-gateway.yaml`).
Both scripts below give it the certificate: a Let's Encrypt wildcard (`development.oanstaging.com` and
`*.development.oanstaging.com`) from acme.sh over DNS-01, written to Secret `oan-development-wildcard-tls` in
`api6-gateway`. The key is generated on the node, not copied from the OpenG2P host's wildcard. DNS-01 works before
Route 53 points at the node, so the gateway can be tested with `curl --resolve` first.

## `oan-tls.sh` (use this one)

Runs the sandbox's `lib/acme.sh` with its own acme.sh home (`/opt/acme-k8s`). The DNS provider is one line of the
config, so the same command covers a node with no DNS permissions and one with a Route 53 role:

| `tls.dns_provider` | What happens |
|---|---|
| `manual` | No DNS API needed. Run 1 prints the `_acme-challenge` TXT records and stops. You add them. Run 2 finishes. Renewals are manual. |
| `route53` | Fully automatic, including renewals. Needs a Route 53 instance role or keys. |

### Steps

On the node, as root, in a checkout of this repository:

```sh
cp automation/oan-dev/oan-tls.example.yaml oan-tls.yaml     # set tls.email; tls.staging: true to start
./automation/oan-dev/oan-tls.sh oan-tls.yaml                  # run 1: prints the TXT records, stops (exit 3)
```

1. In Route 53 (zone `oanstaging.com`) create **one** TXT record `_acme-challenge.development`, TTL 60, with **both**
   printed values (the apex and the wildcard share the name, and Route 53 needs them in one record set).
2. Run the same command again:

   ```sh
   ./automation/oan-dev/oan-tls.sh oan-tls.yaml                # run 2: waits for DNS, completes, applies the Secret
   ```

3. Check what APISIX serves (a staging certificate shows `(STAGING)` in the issuer):

   ```sh
   echo | openssl s_client -connect 127.0.0.1:443 -servername a2c.development.oanstaging.com 2>/dev/null \
     | openssl x509 -noout -issuer -dates
   ```

4. **Real certificate:** set `tls.staging: false` and run it with `--force`. The TXT values are new, so replace the
   old ones, then run it once more. (Skip staging if you prefer: set `staging: false` from the start.)
5. **Renewal, `manual`:** run it again after about 60 days (the certificate lasts 90), with new TXT values each time.
6. **When the node gets a Route 53 role:** set `tls.dns_provider: route53` and run it once with `--force`. After that
   renewals are automatic and the TXT records are no longer touched by hand.

An unfinished order is the file `/opt/acme-k8s/data/manual-pending-<domain>`. `--force` discards it.

The same applies in the sandbox: `tls.dns_provider: manual` in `sandbox-config.yaml` makes its certificate step stop
and resume the same way, and `tls.k8s_secret` makes it apply a Secret instead of writing nginx files.

### Test the frontends and backends

The certificate only covers TLS. Public DNS still points the UIs at other nodes (`a2c`, `grievance`) and the backends at
the OpenG2P server, so nothing reaches APISIX until the records change. A UI calls its backend from its own server
(`API_BASE_URL`, `AUTH_API_BASE_URL`), so a hosts file on a laptop does not exercise that call. For the whole chain,
point `a2c`, `grievance`, `a2c-service` and `grievance-service` at the node with real (not staging) certificates.
A staging certificate is only good for the browser and `curl -k`.

## `oan-k8s-tls.sh`

The earlier standalone script: Route 53 only, with renewals by acme.sh's cron. Superseded by `oan-tls.sh` with
`tls.dns_provider: route53`; see its header for the Route 53 permissions that provider needs.
