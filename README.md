# Databricks on GCP Private Workspace Deployment

This repository provisions Databricks workspaces on Google Cloud with:

- a customer-managed VPC per environment (name and CIDRs from config)
- one regional cluster subnet with Private Google Access (GCS and Google APIs stay on Google's network)
- the intra-subnet firewall rule Databricks requires (`db-<subnet>-ingress`)
- Cloud Router + Cloud NAT for outbound internet access (optional)
- back-end Private Service Connect: workspace REST API and secure cluster connectivity relay endpoints, with a
  private `gcp.databricks.com` DNS zone (optional, Enterprise tier)
- secure cluster connectivity (no public IPs on cluster nodes)
- optional public access to the workspace (controlled by config)
- a Unity Catalog metastore (provisioned by a dedicated stack)
- Unity Catalog metastore assignment
- workspace admin assignment for an account-level group
- workspace bootstrap (GCS bucket, storage credential, external location, catalog, cluster policies, secret scope,
  optional clusters and SQL warehouses)

## Deployment pattern

- Terraform modules contain provisioning logic
- Terragrunt orchestrates deployments
- `live/common.yaml` stores shared settings (GCP project, state bucket); `config.yaml` stores environment-specific inputs

## What this creates

- **Metastore layer (`live/metastore` → `modules/metastore`)**
  - Databricks Unity Catalog metastore (account-level, one per region)
  - Optional metastore-level storage (`storage_root`, with a Databricks-managed GCP service account granted on the bucket)

- **Workspace layer (`live/<env>/workspace` → `modules/dbx_workspace_private`)**
  - VPC, node subnet, firewall rule, Cloud Router and Cloud NAT
  - PSC subnet, internal addresses and forwarding rules, private DNS zone (when PSC is on)
  - Databricks network configuration, VPC endpoint registrations, private access settings
  - Databricks workspace. Databricks itself creates the workspace's GCS root bucket and compute service account in
    the project, so there is no cross-account role or root-bucket module (unlike AWS).
  - Unity Catalog metastore assignment
  - Workspace admin assignment for an account-level group

- **Workspace bootstrap layer (`live/<env>/workspace-bootstrap` → `modules/workspace_bootstrap`)**
  - GCS bucket for Unity Catalog data (`gcs-storage-config.yaml`)
  - Storage credential (Databricks-managed GCP service account) with bucket IAM, and external location (`external-location-config.yaml`)
  - Catalog and grants (`catalog-config.yaml`)
  - Cluster policies (`cluster-policy-config.yaml`)
  - Secret scope (`secret-scope-config.yaml`)
  - Clusters and SQL warehouses (`cluster-config.yaml`, `sql-warehouse-config.yaml`; modules are commented out in `modules/workspace_bootstrap/main.tf`)

## What this does not create

- The GCP project, its billing link and API enablement
- The Terraform state bucket
- The deployer service account and GitHub Workload Identity Federation
- The Databricks account, the admin group, and the deployer's Databricks account-admin role
- UC schemas

## Prerequisites

See [DEPLOYMENT.md](DEPLOYMENT.md) for the full setup and deployment steps. In short:

- GCP project with billing, required APIs enabled, and a GCS bucket `dbx-architect-lab-tfstate-<project-id>` for Terraform state
- A deployer GCP service account that can impersonate itself, trusted by GitHub Workload Identity Federation for
  this repo's `dev`/`uat`/`prod` environments
- Databricks account on GCP (Premium; Enterprise if Private Service Connect is enabled)
- The deployer service account added to the Databricks account as an account admin
- Databricks account group `DBX_Architect_Lab_Admin` containing the deployer service account

## Authentication

Databricks on GCP only accepts **Google-issued OIDC tokens** for account-level APIs (such as workspace creation),
so every stack runs as one GCP service account. There is no Databricks OAuth secret.

| Provider | CI (GitHub Actions) | Local |
| --- | --- | --- |
| Google | Workload Identity Federation → deployer service account (`google-github-actions/auth`) | `gcloud auth application-default login`, optionally `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` |
| Databricks account (`https://accounts.gcp.databricks.com`) | Impersonates `DATABRICKS_GOOGLE_SERVICE_ACCOUNT` (Google ID token) | Same environment variable; your user needs Token Creator on the service account |
| Databricks workspace (workspace-bootstrap) | Same service account (workspace admin through `DBX_Architect_Lab_Admin`) | Same, or `databricks auth login` + `DATABRICKS_AUTH_TYPE=databricks-cli` |

### Required environment variables

| Variable | Used for |
| --- | --- |
| `DATABRICKS_ACCOUNT_ID` | Databricks account-level provider and account resources |
| `DATABRICKS_GOOGLE_SERVICE_ACCOUNT` | Deployer service account email the Databricks provider impersonates. Also the deployment principal granted on the catalog and external location. |
| `DATABRICKS_METASTORE_ID` | Unity Catalog metastore assigned to the workspace (`*/workspace` stacks and their dependents) |
| `DEPLOY_PRINCIPAL` (optional) | Overrides the principal added to catalog and external location grants; defaults to `DATABRICKS_GOOGLE_SERVICE_ACCOUNT` |

Google credentials come from Application Default Credentials. The GCP project ID comes from `live/common.yaml`
(overridable per environment) and is appended to bucket names to keep them globally unique.

## Run

```bash
# 1. Metastore (once per region), then set DATABRICKS_METASTORE_ID to its metastore_id output
cd live/metastore && terragrunt apply

# 2. Workspace
cd live/dev/workspace && terragrunt apply

# 3. Workspace bootstrap (needs the workspace stack applied)
cd live/dev/workspace-bootstrap && terragrunt apply
```

Run `terragrunt plan` first in each directory.

### GitHub Actions

`.github/workflows/terragrunt-deploy.yml` is run manually (workflow dispatch). Pick a stack (`metastore`,
`dev-*`, `uat-*` or `prod-*`) and an action (`validate`, `plan`, `apply` or `destroy`). The job runs in the
matching GitHub environment (`prod-*` → `prod`, `uat-*` → `uat`, everything else → `dev`) and reads its
secrets from there.

## Ported from AWS

This repo was ported from `dbx-platform-infra-aws`. The stack layout, workflow and configuration style are the same.
The cloud resources map like this:

| AWS | GCP |
| --- | --- |
| AWS account ID suffix on bucket names | GCP project ID suffix |
| S3 state bucket + `use_lockfile` | GCS state bucket (native locking) |
| GitHub OIDC → IAM role | GitHub OIDC → Workload Identity Federation → deployer service account |
| Databricks service principal (OAuth M2M) | Deployer GCP service account (Google ID tokens) |
| VPC, two AZ subnets, route tables | VPC with one regional subnet |
| Security group | Firewall rule `db-<subnet>-ingress` |
| Internet gateway + NAT gateway + EIP | Cloud Router + Cloud NAT |
| S3 gateway endpoint | Private Google Access |
| PrivateLink (workspace + relay VPC endpoints) | Private Service Connect (forwarding rules + private DNS zone) |
| Cross-account IAM role + `databricks_mws_credentials` | Not needed (Databricks creates its compute service account) |
| S3 root bucket + `databricks_mws_storage_configurations` | Not needed (Databricks creates the root GCS bucket) |
| UC IAM role + trust policy (external ID) | Databricks-managed GCP service account + bucket IAM |
| `aws_attributes`, `m5d.*` node types | `gcp_attributes`, `n2-standard-*` node types |
| Tags | Labels (lowercase keys and values) |
| `us-east-2` | `us-central1` |
