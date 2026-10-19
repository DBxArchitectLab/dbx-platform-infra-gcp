# Databricks on GCP Private Workspace Deployment

Part of **DBX Architect Lab**, an enterprise Databricks platform built in public:
[YouTube](https://www.youtube.com/@DBxArchitectLab) ·
[LinkedIn](https://www.linkedin.com/in/DBxArchitectLab) ·
[GitHub](https://github.com/DBxArchitectLab)

This repository provisions Databricks workspaces on Google Cloud with:

- a customer-managed VPC per environment (name and CIDRs from config)
- one regional cluster subnet with Private Google Access (GCS and Google APIs stay on Google's network)
- the intra-subnet firewall rule Databricks requires (`db-<subnet>-ingress`)
- Cloud Router + Cloud NAT for outbound internet access (on by default; it can be turned off only when Private
  Service Connect is on, because clusters need one path to the control plane)
- back-end Private Service Connect: workspace REST API and secure cluster connectivity relay endpoints, with a
  private `gcp.databricks.com` DNS zone (optional, Enterprise tier)
- secure cluster connectivity (no public IPs on cluster nodes)
- with Private Service Connect on, optional public access to the workspace UI and API
  (`private_service_connect.public_access_enabled`)
- a Unity Catalog metastore (provisioned by a dedicated stack)
- Unity Catalog metastore assignment
- workspace admin assignment for an account-level group
- workspace bootstrap (GCS bucket, storage credential, external location, catalog, cluster policies, secret scope,
  validation notebook)

As configured, Private Service Connect is **off** in dev, uat and prod (`private_service_connect.enabled: false` in
`live/<env>/config.yaml`), so the workspaces run on the Premium tier: clusters reach the control plane through
Cloud NAT, and the workspace UI and API are reachable from the internet. Set it to `true` on the Enterprise tier.

## Deployment pattern

- Terraform modules contain provisioning logic
- Terragrunt orchestrates deployments
- `live/root.hcl` generates the GCS state backend and the providers for every stack
- `live/common.yaml` stores shared settings (GCP project, state bucket)
- `live/metastore/config.yaml` and `live/<env>/config.yaml` store each stack's inputs; each folder's `env.hcl`
  reads `common.yaml` plus its `config.yaml`
- `live/<env>/workspace-bootstrap/*-config.yaml` describe the bootstrap objects (bucket, external location,
  catalog, cluster policies, secret scope)

## What this creates

- **Metastore layer (`live/metastore` → `modules/metastore`)**
  - Databricks Unity Catalog metastore (account-level, one per region), owned by `DBX_Architect_Lab_Admin`
  - Optional metastore-level storage (`storage_root`, with a Databricks-managed GCP service account granted on the bucket)

- **Workspace layer (`live/<env>/workspace` → `modules/dbx_workspace_private`)**
  - VPC, node subnet, firewall rule, Cloud Router and Cloud NAT
  - PSC subnet, internal addresses and forwarding rules, private DNS zone (when PSC is on)
  - Databricks network configuration (plus VPC endpoint registrations and private access settings when PSC is on)
  - Databricks workspace. Databricks itself creates the workspace's GCS root buckets and compute service account in
    the project.
  - Unity Catalog metastore assignment
  - Workspace admin assignment for an account-level group

- **Workspace bootstrap layer (`live/<env>/workspace-bootstrap` → `modules/workspace_bootstrap`)**
  - GCS bucket for Unity Catalog data (`gcs-storage-config.yaml`)
  - Storage credential (Databricks-managed GCP service account) with bucket IAM, and external location and its
    grants (`external-location-config.yaml`)
  - Catalog and grants (`catalog-config.yaml`), with managed storage at `gs://<bucket>/managed/<catalog>/`
  - Cluster policies (`cluster-policy-config.yaml`)
  - Secret scope (`secret-scope-config.yaml`)
  - Validation notebook `/Shared/platform/workspace-bootstrap-validation`, with this environment's expected values
    in `/Shared/platform/workspace-bootstrap-validation.json`
    (`modules/workspace_bootstrap/notebooks/workspace-bootstrap-validation.py`; see
    [DEPLOYMENT.md section 8](DEPLOYMENT.md#8-verify))

dev, uat and prod share one metastore. The catalog, storage credential and external location are created in
isolated mode, so each is bound only to its own environment's workspace.

## What this does not create

- The GCP project, its billing link and API enablement
- The Terraform state bucket
- The deployer service account and GitHub Workload Identity Federation
- The Databricks account, the admin group, and the deployer's Databricks account-admin role
- UC schemas
- Clusters and SQL warehouses: `cluster-config.yaml` and `sql-warehouse-config.yaml` are present, but their modules
  are commented out in `modules/workspace_bootstrap/main.tf`

## Prerequisites

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full setup and deployment steps. Two scripts cover the setup:

- `scripts/setup-gcp-prerequisites.sh`: one-time GCP setup (APIs, state bucket, deployer service account and roles,
  Workload Identity Federation). Safe to re-run.
- `scripts/preflight-check.sh`: read-only check of every prerequisite, including the Databricks account; prints the
  fix for each failure.

In short:

- GCP project with billing, required APIs enabled, and a GCS bucket `dbx-architect-lab-tfstate-<project-id>` for Terraform state
- A deployer GCP service account that can impersonate itself, trusted by GitHub Workload Identity Federation for
  this repo's `dev`/`uat`/`prod` environments
- Databricks account on GCP (Premium; Enterprise if Private Service Connect is enabled)
- The deployer service account added to the Databricks account as an account admin
- Databricks account group `DBX_Architect_Lab_Admin` containing the deployer service account
- The users named in the bootstrap grants (`grant_principals`) exist in the Databricks account
- Each workspace in the same region as the metastore (`us-central1` in this configuration)

Tools: Terraform >= 1.10 and Terragrunt (CI uses Terraform 1.14.6 and Terragrunt 0.99.4). Providers: `google`
>= 6.0, < 8.0; `databricks` >= 1.105.0; `time` ~> 0.12.

## Authentication

Databricks on GCP only accepts **Google-issued OIDC tokens** for account-level APIs (such as workspace creation),
so every stack runs as one GCP service account. There is no Databricks OAuth secret.

| Provider | CI (GitHub Actions) | Local |
| --- | --- | --- |
| Google | Workload Identity Federation → deployer service account (`google-github-actions/auth`) | `gcloud auth application-default login`, optionally `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` |
| Databricks account (`https://accounts.gcp.databricks.com`) | Impersonates `DATABRICKS_GOOGLE_SERVICE_ACCOUNT` to mint Google ID and access tokens (the service account has Token Creator on itself) | Same environment variable; your user needs Token Creator on the service account |
| Databricks workspace (workspace-bootstrap) | Same service account (workspace admin through `DBX_Architect_Lab_Admin`) | Same, or `databricks auth login` + `DATABRICKS_AUTH_TYPE=databricks-cli` (see [DEPLOYMENT.md section 9](DEPLOYMENT.md#9-running-locally)) |

### Required environment variables

| Variable | Used for |
| --- | --- |
| `DATABRICKS_ACCOUNT_ID` | Databricks account-level provider and account resources |
| `DATABRICKS_GOOGLE_SERVICE_ACCOUNT` | Deployer service account email the Databricks provider impersonates. Also the deployment principal granted on the catalog and external location. |
| `DATABRICKS_METASTORE_ID` | Unity Catalog metastore assigned to the workspace (required by the `*/workspace` stacks; optional in workspace-bootstrap, where it only feeds the validation notebook) |
| `DEPLOY_PRINCIPAL` (optional) | Overrides the principal added to catalog and external location grants; defaults to `DATABRICKS_GOOGLE_SERVICE_ACCOUNT` |

Google credentials come from Application Default Credentials. The GCP project ID comes from `live/common.yaml`
(overridable per environment) and is appended to bucket names to keep them globally unique.

## Run

Run `terragrunt plan` before each apply. From the repository root, after setting the environment variables above
(see [DEPLOYMENT.md section 9](DEPLOYMENT.md#9-running-locally)):

```bash
# 1. Metastore (once per region), then set DATABRICKS_METASTORE_ID to its metastore_id output
(cd live/metastore && terragrunt apply)

# 2. Workspace
(cd live/dev/workspace && terragrunt apply)

# 3. Workspace bootstrap (needs the workspace stack applied)
(cd live/dev/workspace-bootstrap && terragrunt apply)
```

Repeat steps 2 and 3 for `uat` and `prod`.

### GitHub Actions

The **Terragrunt Deploy Stacks** workflow (`.github/workflows/terragrunt-deploy.yml`) is run manually (workflow
dispatch). Pick a stack (`metastore`, or `<env>-dbxarchitectlab-workspace` /
`<env>-dbxarchitectlab-workspace-bootstrap` for `dev`, `uat` or `prod`) and an action (`validate`, `plan`, `apply`
or `destroy`). The job runs in the matching GitHub environment (`prod-*` → `prod`, `uat-*` → `uat`, everything
else, including `metastore` → `dev`) and reads its secrets from there.

Each of the `dev`, `uat` and `prod` environments (named exactly so; Workload Identity Federation trusts these names)
needs these secrets:

| Secret | Value |
| --- | --- |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Full resource name of the Workload Identity provider |
| `GCP_DEPLOYER_SERVICE_ACCOUNT` | Deployer service account email (passed to Terragrunt as `DATABRICKS_GOOGLE_SERVICE_ACCOUNT`) |
| `DATABRICKS_ACCOUNT_ID` | Databricks account ID |
| `DATABRICKS_METASTORE_ID` | The metastore stack's `metastore_id` output; a placeholder until the metastore exists |

`apply` and `destroy` run with `-auto-approve`; add required reviewers to the `prod` environment if you want a
manual gate.

### Destroy

Destroy in reverse order: `<env>-dbxarchitectlab-workspace-bootstrap`, then `<env>-dbxarchitectlab-workspace` for
each environment, then `metastore`. See [DEPLOYMENT.md](DEPLOYMENT.md#destroying) for the clean-up afterwards.

- A workspace destroy takes 10+ minutes: it waits for Databricks to finish deleting the workspace before deleting
  its network.
- `force_destroy` is on for the Unity Catalog bucket, catalog and external location in every environment, and for
  the metastore, so destroy deletes their data too.
- Apply also includes short waits for IAM to propagate: 90 seconds after the storage credential's service account
  is created, and 30 seconds after the bucket IAM grant.

## DBX Architect Lab

This repository is part of **DBX Architect Lab**: one enterprise Databricks platform on Azure, AWS and Google
Cloud, built in public. The videos walk through the architecture and the deployment step by step.

- YouTube: [youtube.com/@DBxArchitectLab](https://www.youtube.com/@DBxArchitectLab)
- LinkedIn: [linkedin.com/in/DBxArchitectLab](https://www.linkedin.com/in/DBxArchitectLab)
- GitHub: [github.com/DBxArchitectLab](https://github.com/DBxArchitectLab)

## Contributing and license

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Licensed under the
[Apache License 2.0](LICENSE); see also [NOTICE](NOTICE).
