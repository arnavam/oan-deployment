# QA environment (`qa.oanstaging.com`)

One RKE2 cluster on one node, one namespace per service, PostgreSQL and the UIs in the cluster: the oan_dev layout,
installed by automation instead of by hand. This repository holds only that automation and its configuration.
Every OAN chart and its QA values live in [oan-helm](https://github.com/Centre-for-Open-Societal-Systems/oan-helm)
(`environments/qa`, installed by hand in `docs/qa-cluster.md` there); `platform-config.yaml` pins the oan-helm
commit and chart versions used.

| Set up by | What |
|---|---|
| `automation/sandbox` (`edge: apisix`, `logging: external`) | RKE2, firewall, WireGuard, NFS, Let's Encrypt wildcard, APISIX on 80/443 with its etcd, Rancher (through APISIX, private addresses only), Prometheus and Alertmanager. No Grafana, Loki or OpenTelemetry. |
| `automation/oan-platform.sh` | `oan-namespace-guard`, `oan-frappe-common-db`, `oan-cluster-access` (the Jenkins deployer), `oan-logging` (the node agent) |
| Jenkins | a2c, grievance, da-app, farmer-app, leads, sandbox: their releases, gateways and UIs |

The namespaces, their Pod Security levels and who may reach them are in oan-helm
`environments/qa/values/oan-namespace-guard.yaml`.

## Install

1. **Node.** Provision it (`automation/sandbox/aws/openg2p-aws-provision.sh`) or use an existing VM. Give it a Route 53
   role on `oanstaging.com` for the certificate, and open 80/443 in the security group.
2. **Platform.** From the laptop:

   ```sh
   cp environments/qa/platform-config.example.yaml environments/qa/platform-config.yaml   # fill tls.email, ssh_*
   ./automation/sandbox/openg2p-sandbox.sh --config environments/qa/platform-config.yaml
   ```

3. **OAN platform.** The central OTel gateway must be set in oan-helm `environments/qa/values/oan-logging.yaml` at
   `oan_helm.ref`. Then, over WireGuard with the cluster's kubeconfig (or on the node):

   ```sh
   ./automation/oan-platform.sh environments/qa/platform-config.yaml
   ```

4. **Jenkins access.** Turn the token of ServiceAccount `jenkins-qa-deployer` (namespace `a2c`) into a kubeconfig with
   `cluster/write-kubeconfig.sh` from oan-service-helm and store it in Jenkins as a Secret file credential.
5. **Services.** Run the Jenkins pipelines with the QA values of each service repository.
6. **DNS.** Point `*.qa.oanstaging.com` at the node in Route 53 once `curl --resolve` against it works.

To pick up a change merged in oan-helm, move `oan_helm.ref` (and a chart version, if it changed) and re-run the
step that installs it.
