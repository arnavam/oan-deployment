# OAN Deployment

The cluster the OAN services (A2C, grievance, DA app, farmer app, leads, sandbox) run on: one Kubernetes cluster,
one namespace per service, with PostgreSQL and the frontends in the cluster. This repository sets up the cluster;
Jenkins deploys the services from their own repositories. It holds no charts or values of its own: those live in
[oan-helm](https://github.com/Centre-for-Open-Societal-Systems/oan-helm), where the same steps can be run by hand.

Derived from [OpenG2P deployment](https://github.com/OpenG2P/openg2p-deployment) (remote `upstream`): the platform
is installed by its sandbox automation, the single-VM path, with APISIX instead of nginx and Istio as the edge.

## Layout

| Path | Purpose |
|------|---------|
| [`environments/qa/`](environments/qa/) | QA on `qa.oanstaging.com`: the platform config, pinning the oan-helm commit and chart versions. Start with its [README](environments/qa/README.md). |
| [`automation/sandbox/`](automation/sandbox/) | Single-VM platform: RKE2, WireGuard, NFS, Rancher, monitoring, logging, Let's Encrypt over DNS-01 (Route 53 or manual). `edge: apisix` puts APISIX on 80/443; `logging: external` leaves out Grafana, Loki and OpenTelemetry for oan-logging. |
| [`automation/oan-platform.sh`](automation/oan-platform.sh) | Installs the cluster-level OAN releases from oan-helm once the platform is up: namespace guard, shared PostgreSQL, Jenkins deployer, log agent. |
| [`automation/oan-dev/`](automation/oan-dev/) | Certificate scripts for the `oan_dev` k3s node, where APISIX is the edge. |
| [`automation/lib/`](automation/lib/) | Shell helpers shared by the scripts (logging, config, AWS). |
| [`nfs-server/`](nfs-server/), [`kubernetes/nfs-client/`](kubernetes/nfs-client/) | NFS server and CSI driver, installed by the sandbox's phase 1. |

Backups are not set up yet. OpenG2P's backup automation assumed its 3-node layout and was removed; it is in the
`upstream` history if it is needed as a reference.

## Environments

| Environment | Domain | State |
|---|---|---|
| dev (`oan_dev`) | `development.oanstaging.com` | Installed by hand on k3s; its values are in oan-helm `environments/dev`. |
| qa | `qa.oanstaging.com` | Defined in `environments/qa/`. |

## License

This repository is licensed under [MPL-2.0](LICENSE).
