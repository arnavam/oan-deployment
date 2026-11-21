# QA environment (`qa.oanstaging.com`)

One RKE2 cluster on one node, one namespace per service, PostgreSQL and the UIs in the cluster: the oan_dev layout,
built from this repository instead of by hand. This repository sets up the cluster; Jenkins deploys the services
from their own repositories with their QA values.

| Set up by | What |
|---|---|
| `automation/sandbox` (`platform-config.yaml`, `edge: apisix`, `logging: external`) | RKE2, firewall, WireGuard, NFS, Let's Encrypt wildcard, APISIX on 80/443, Rancher (through APISIX, private addresses only), Prometheus and Alertmanager. No Grafana, Loki or OpenTelemetry. |
| `automation/oan-platform.sh` (`platform.yaml`) | Namespaces with Pod Security and NetworkPolicies, the shared Frappe PostgreSQL, the Jenkins deployer, the oan-logging node agent |
| Jenkins | a2c, grievance, da-app, farmer-app, leads, sandbox: their releases, gateways and UIs |

## Namespaces

| Namespace | Holds | Accepts traffic from |
|---|---|---|
| `api6-gateway` | APISIX, its etcd and Redis (platform) | anywhere: it is the edge. Pod Security `privileged` (hostPort 80/443) |
| `frappe-common` | `oan-frappe-common-db`, the shared PostgreSQL (platform) | a2c, grievance, da-app, farmer-app |
| `observability` | `oan-logging`: the node log agent (platform) | nothing: it only sends. Pod Security `privileged` (hostPath `/var/log/pods`) |
| `a2c`, `grievance`, `da-app`, `farmer-app`, `leads`, `sandbox` | the services (Jenkins) | APISIX |

Every namespace also accepts its own pods and Prometheus (`cattle-monitoring-system`). The app namespaces enforce
Pod Security `baseline` and warn on `restricted`. Change either in `charts/namespace-guard/values.yaml`.

## Install

1. **Node.** Provision it (`automation/sandbox/aws/openg2p-aws-provision.sh`) or use an existing VM. Give it a Route 53
   role on `oanstaging.com` for the certificate, and open 80/443 in the security group.
2. **Platform.** From the laptop:

   ```sh
   cp environments/qa/platform-config.example.yaml environments/qa/platform-config.yaml   # fill tls.email, ssh_*
   ./automation/sandbox/openg2p-sandbox.sh --config environments/qa/platform-config.yaml
   ```

3. **OAN platform.** Set the central OTel gateway in `values/oan-logging.yaml` (`<host>:<port>`, reachable from the
   node over the private network). Then, over WireGuard with the cluster's kubeconfig (or on the node):

   ```sh
   ./automation/oan-platform.sh environments/qa
   ```

4. **Jenkins access.** Turn the token of ServiceAccount `jenkins-qa-deployer` (namespace `a2c`) into a kubeconfig with
   `cluster/write-kubeconfig.sh` from oan-service-helm and store it in Jenkins as a Secret file credential.
5. **Services.** Run the Jenkins pipelines with the QA values of each service repository.
6. **DNS.** Point `*.qa.oanstaging.com` at the node in Route 53 once `curl --resolve` against it works.

Logs are read in the central Grafana, filtered by `k8s.namespace.name`; nothing on this cluster stores them.
APISIX has no catch-all on QA: a host without a route of its own gets a 404. See `values/apisix.yaml`.
