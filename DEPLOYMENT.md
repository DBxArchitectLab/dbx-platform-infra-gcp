# Deployment guide

How to deploy this repository into a GCP project and a Databricks account (on GCP) using the GitHub Actions
workflow (`.github/workflows/terragrunt-deploy.yml`), or locally.

Deployment order:

```
Before you begin (accounts)  →  0. Tools  →  1. Repo config  →  2. GCP prerequisites (Cloud Shell)
                                                                                     │
   3. Databricks account  →  4. GitHub setup  →  5. Deploy: metastore → dev-workspace → dev-workspace-bootstrap → (uat, prod)
```

Values used throughout this guide (change them if yours differ):

| Name | Value | Defined in |
| --- | --- | --- |
| GCP project ID | `dbx-architect-lab` (placeholder, **set your own**) | `live/common.yaml` (`gcp_project_id`), optionally per env in `live/<env>/config.yaml` |
| GCP region | `us-central1` | `live/<env>/config.yaml`, `live/metastore/config.yaml`, `live/common.yaml` (`state.location`) |
| Terraform state bucket | `dbx-architect-lab-tfstate-<project-id>` | `live/common.yaml` + `live/root.hcl` |
| Unity Catalog buckets | `dbx-architect-lab-<env>-uc-<project-id>` | `live/<env>/workspace-bootstrap/gcs-storage-config.yaml` |
| Deployer service account | `sa-dbx-platform-infra@<project-id>.iam.gserviceaccount.com` | step 2.3 |
| Admin group | `DBX_Architect_Lab_Admin` | `live/<env>/config.yaml`, `live/metastore/config.yaml` |
| GitHub repo | `DBxArchitectLab/dbx-platform-infra-gcp` (org ID `336295900`, repo ID `1404588588`) | Workload Identity provider condition (step 2.4) |

---

## Before you begin: accounts

1. **A GCP project with billing.** Create a project (or use an existing one) linked to an active billing account.
   The free trial can work for a small lab, but its CPU quotas are low (see step 2.5). A dev environment has a small
   fixed cost (Cloud NAT) on top of cluster usage.
2. **A Databricks account on GCP.** Subscribe through **Google Cloud Marketplace** (search "Databricks" →
   **Subscribe**, pick the billing account → **Sign up with Databricks**) or at
   <https://www.databricks.com/try-databricks>, choosing Google Cloud. The person who subscribes becomes the first
   **account admin**. The account console is <https://accounts.gcp.databricks.com>.
   - The tier matters: **Premium** works with this repo as configured; **Enterprise** is needed to turn on
     Private Service Connect (step 1).
   - If the signup created a default workspace or a Unity Catalog metastore, this repo doesn't manage it. Check
     step 3.5 for the metastore.
3. **If the project sits in a GCP Organization** with organization policies, check these before you start:
   - `constraints/iam.allowedPolicyMemberDomains` (domain-restricted sharing) can block the IAM bindings Databricks
     adds for its own service accounts during workspace creation and for Unity Catalog storage credentials. See
     **Troubleshooting**.
   - `constraints/compute.vmExternalIpAccess` is fine: cluster VMs have no public IPs.
   - `constraints/gcp.resourceLocations` must allow your region.

## 0. Tools (for local runs and the one-time setup)

| Tool | Version | Notes |
| --- | --- | --- |
| gcloud CLI | recent | For steps 2.x. Not needed if you use **Cloud Shell** (recommended, see step 2) |
| Terraform | ≥ 1.10 (CI uses 1.14.6) | |
| Terragrunt | recent (CI uses 0.99.4) | Match CI for local runs; very old releases (e.g. 0.63) use older CLI flags |
| Databricks CLI | optional | Only for local runs as your own user (`databricks auth login`) |

## 1. Finish the repo configuration

Edit and commit these before the first run.

- [ ] **GCP project.** Set `gcp_project_id` in `live/common.yaml` to your project ID. All environments use it unless
      a `live/<env>/config.yaml` sets its own `gcp_project_id` (to give an environment its own project; repeat the
      step 2 grants in that project).
- [ ] **Region.** Everything defaults to `us-central1`. To change it, update `region` in every
      `live/<env>/config.yaml`, `metastore.region` in `live/metastore/config.yaml`, `state.location` in
      `live/common.yaml`, and the PSC service attachments (below). The metastore and all workspaces must be in the
      same region, and the region must be one Databricks supports on GCP.
- [ ] **Private Service Connect (`private_service_connect.enabled` in `live/<env>/config.yaml`).** Off,
      because **back-end PSC requires the Enterprise tier**. Clusters reach the control plane through Cloud NAT.
      After an upgrade to Enterprise, set `enabled: true` to add the PSC endpoints and the private DNS zone.
- [ ] **PSC service attachments.** `workspace_service_attachment` and `relay_service_attachment` are
      region-specific. Check the values against the Databricks table at
      <https://docs.databricks.com/gcp/en/resources/ip-domain-region#psc>.
- [ ] **CIDRs.** dev, uat and prod use node subnets `10.0.0.0/22`, `10.1.0.0/22` and `10.2.0.0/22` (PSC subnets
      `10.x.4.0/28`). Each cluster node uses one IP. Change them if they overlap with networks you plan to peer with.
- [ ] **Grant principals.** `grant_principals` in `catalog-config.yaml` and `external-location-config.yaml`
      (e.g. `dbxarchitectlab@gmail.com`) must be users or groups that exist in the Databricks account.
- [ ] **Metastore owner.** `metastore.owner` in `live/metastore/config.yaml` must exist in the account.
      Recommended: the group `DBX_Architect_Lab_Admin` (step 3).
- [ ] **Labels.** `labels` in `live/<env>/config.yaml` become GCP labels: lowercase keys and values, letters, digits,
      `_` and `-` only. Terraform rejects anything else.
- [ ] **Bucket name length.** GCS names are at most 63 characters. `dbx-architect-lab-prod-uc-` plus your project ID
      must fit; shorten `name_prefix` if your project ID is long.

## 2. GCP prerequisites

Run these as a user with **Owner** on the project.

**Recommended: Cloud Shell.** Open the GCP console, select the project, and click **Activate Cloud Shell** (`>_`)
in the top bar. Cloud Shell has `gcloud` and `jq` installed and is already signed in as you. Paste the commands below
into it. Alternatively, use gcloud on your machine (step 0).

```bash
export PROJECT_ID="<your-project-id>"          # same value as gcp_project_id in live/common.yaml
export REGION="us-central1"
gcloud config set project "$PROJECT_ID"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
ME=$(gcloud config get-value account)
echo "$PROJECT_ID / $PROJECT_NUMBER / $ME"
```

### 2.1 Enable APIs

```bash
gcloud services enable \
  compute.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  dns.googleapis.com
```

`iamcredentials` and `sts` are needed for Workload Identity Federation and service account impersonation; `dns` only
matters with PSC. Databricks enables anything else it needs during workspace creation.

### 2.2 Terraform state bucket

`live/root.hcl` expects `dbx-architect-lab-tfstate-<project-id>` in `us-central1`. The GCS backend locks state
natively, so no lock table is needed.

```bash
STATE_BUCKET="dbx-architect-lab-tfstate-$PROJECT_ID"

gcloud storage buckets create "gs://$STATE_BUCKET" --location="$REGION" \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update "gs://$STATE_BUCKET" --versioning
```

### 2.3 Deployer service account

Every stack runs as this service account. Databricks on GCP only accepts Google-issued OIDC tokens for account-level
APIs (no Databricks OAuth secret is involved).

```bash
SA_NAME="sa-dbx-platform-infra"
SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

gcloud iam service-accounts create "$SA_NAME" --display-name="Databricks platform infra deployer"

# Project permissions: create the VPC/NAT/firewall/buckets, and let Databricks set up the workspace
# (it creates a service account, custom roles and IAM bindings in the project using the creator's permissions).
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/owner" --condition=None

# Explicit read/write on the Terraform state bucket (step 2.2). Basic roles such as Owner don't reliably grant
# object access on a bucket with uniform bucket-level access; without this, `terragrunt init` fails with
# "does not have storage.objects.list access".
gcloud storage buckets add-iam-policy-binding "gs://dbx-architect-lab-tfstate-$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/storage.objectAdmin"

# The Databricks provider mints Google ID/access tokens for this service account by impersonation, so it must be
# allowed to impersonate itself (CI), and you must be allowed to impersonate it (local runs, step 3.6).
for MEMBER in "serviceAccount:$SA_EMAIL" "user:$ME"; do
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --member="$MEMBER" --role="roles/iam.serviceAccountTokenCreator"
done

echo "$SA_EMAIL"   # → GCP_DEPLOYER_SERVICE_ACCOUNT GitHub secret, and the user you add to Databricks in step 3.2
```

`roles/owner` keeps a lab simple. For production, Databricks documents the minimum as **Editor + Project IAM Admin**
(`roles/editor`, `roles/resourcemanager.projectIamAdmin`) on the workspace project. Add **Storage Admin**
(`roles/storage.admin`) so Terraform can set bucket IAM for Unity Catalog, and **DNS Admin** (`roles/dns.admin`) if
PSC is on. The state bucket needs `roles/storage.objectAdmin`.

### 2.4 Workload Identity Federation for GitHub Actions (no service account keys)

The pool trusts GitHub's OIDC issuer. The provider only accepts tokens from this repo, and only for jobs running in
its `dev`, `uat` or `prod` GitHub environments. The repo is matched by its numeric ID, which doesn't change if the
repo or org is renamed.

The repo ID of `DBxArchitectLab/dbx-platform-infra-gcp` is `1404588588`. To check it, run
`curl -s https://api.github.com/repos/DBxArchitectLab/dbx-platform-infra-gcp | jq .id`, or look at the
`repository_id` that the workflow's **Show OIDC claims** step prints.

```bash
REPO_ID="1404588588"
GH_ORG_ID="336295900"

gcloud iam workload-identity-pools create github \
  --location=global --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc dbx-platform-infra-gcp \
  --location=global --workload-identity-pool=github \
  --display-name="dbx-platform-infra-gcp" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.environment=assertion.environment" \
  --attribute-condition="assertion.repository_owner_id == '${GH_ORG_ID}' && assertion.repository_id == '${REPO_ID}' && assertion.environment in ['dev', 'uat', 'prod']"

# Let workflow runs from this repo impersonate the deployer service account.
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository_id/${REPO_ID}"

echo "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/dbx-platform-infra-gcp"
# → save this as the GCP_WORKLOAD_IDENTITY_PROVIDER GitHub secret
```

A new provider can take a few minutes to start accepting tokens.

### 2.5 Quotas

Each environment uses one VPC, one Cloud Router and one Cloud NAT; the default quotas cover dev/uat/prod. The usual
limit is **CPUs**: Databricks clusters on GCP use N2 machines by default, and new projects often have a low
`N2_CPUS` (and `CPUS_ALL_REGIONS`) quota per region. The sample clusters can need up to ~80 vCPUs each at full
autoscale. Check and request increases under **IAM & Admin → Quotas & System Limits**, or:

```bash
gcloud compute regions describe "$REGION" --format=json \
  | jq -r '.quotas[] | select(.metric|test("^(CPUS|N2_CPUS|IN_USE_ADDRESSES|SSD_TOTAL_GB)$")) | "\(.metric)\t\(.usage)/\(.limit)"'
```

## 3. Databricks account

1. **Account and ID.** Sign in to the account console at <https://accounts.gcp.databricks.com> as an account
   admin and copy the account ID from the user menu (top right). Check the plan: **Enterprise** is needed for
   PSC (step 1).
2. **Add the deployer service account as an account admin.** **User management → Users → Add user**, with the service account email from
   step 2.3 (`sa-dbx-platform-infra@<project-id>.iam.gserviceaccount.com`) as the email. Open it → **Roles** tab →
   turn on **Account admin**. There is no secret to generate: the service account proves its identity with
   Google-issued tokens.
3. **Create the group `DBX_Architect_Lab_Admin`** (**User management → Groups**) and add the deployer service
   account user and your user to it. The workspace stack makes this group a workspace admin, which is also how the
   service account gets access to each workspace for the `workspace-bootstrap` stack.
4. **Add the users** named in the `grant_principals` lists (**User management → Users**), if they don't
   exist yet.
5. **Check for an existing metastore.** Go to **Catalog** in the account console. An account can have only one
   metastore per region, so if one already exists in `us-central1` the `metastore` stack will fail. Either:
   - **Use it:** skip the `metastore` stack, copy that metastore's ID for step 4, and make
     `DBX_Architect_Lab_Admin` its admin; or
   - **Replace it:** delete it (only if nothing uses it), then deploy the `metastore` stack.

The service account creates the storage credential, external location and catalog in `workspace-bootstrap`, so it
must be a metastore admin. Setting `metastore.owner` to `DBX_Architect_Lab_Admin`, with the service account in
that group, covers this.

6. **(Optional) Check the service account from Cloud Shell.** This confirms you can impersonate it, that it's an
   account admin, lists existing metastores, and checks the group:

   ```bash
   read -p "Databricks account ID: " DBX_ACCOUNT_ID
   ACC="https://accounts.gcp.databricks.com"

   TOKEN=$(gcloud auth print-identity-token --impersonate-service-account="$SA_EMAIL" \
     --audiences="$ACC" --include-email 2>/dev/null)
   [ -n "$TOKEN" ] && echo "OK: ID token issued" || echo "FAIL: no Token Creator on $SA_EMAIL (step 2.3)"

   echo "== Metastores (PERMISSION_DENIED / 401 = service account isn't an account admin)"
   curl -s -H "Authorization: Bearer $TOKEN" "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/metastores" \
     | jq -r 'if (.metastores | length) > 0 then (.metastores[] | "\(.region)  \(.name)  \(.metastore_id)")
              elif .error_code then "FAIL: \(.error_code) \(.message)" else "none" end'

   echo "== Group DBX_Architect_Lab_Admin members"
   curl -s -G -H "Authorization: Bearer $TOKEN" --data-urlencode 'filter=displayName eq "DBX_Architect_Lab_Admin"' \
     "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/scim/v2/Groups" \
     | jq -r '.Resources[0] // empty | .members[]? | "  - \(.display)"'
   ```

## 4. GitHub setup

1. **Merge to `main`.** A workflow that you start manually only appears in the **Actions** tab once it
   exists on the default branch.
2. **Create environments** under **Settings → Environments**: `dev`, `uat`, `prod`. The names must match
   the Workload Identity provider condition (step 2.4). Consider adding required reviewers on `prod`.
3. **Add these secrets to each environment:**

   | Secret | Value |
   | --- | --- |
   | `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<project-number>/locations/global/workloadIdentityPools/github/providers/dbx-platform-infra-gcp` (step 2.4) |
   | `GCP_DEPLOYER_SERVICE_ACCOUNT` | `sa-dbx-platform-infra@<project-id>.iam.gserviceaccount.com` (step 2.3) |
   | `DATABRICKS_ACCOUNT_ID` | account ID (step 3.1) |
   | `DATABRICKS_METASTORE_ID` | metastore ID (set after step 5.1 or 3.5; any placeholder until then) |

   The `metastore` stack runs in the `dev` environment. The workflow passes `GCP_DEPLOYER_SERVICE_ACCOUNT` to
   Terraform as `DATABRICKS_GOOGLE_SERVICE_ACCOUNT`, which is also the principal added to the catalog and external
   location grants, so no other secret is needed.

## 5. Deploy

Go to **Actions → Terragrunt Deploy Stacks → Run workflow**, choose a **stack** and an **action**. For
each stack, run `plan` first, review the log, then run `apply`.

The **Show runtime identity** step fails early if the service account can't mint a Google ID token for itself. That
is the most common setup error (step 2.3).

### 5.1 Metastore (once per region)

| Stack | Action |
| --- | --- |
| `metastore` | `plan`, then `apply` |

Copy the metastore ID from the `metastore_id` output at the end of the apply log (or from the account
console: **Catalog → your metastore**). Set it as `DATABRICKS_METASTORE_ID` in the `dev`, `uat` and `prod`
environments. They share the metastore because they're in the same region.

### 5.2 dev

| Order | Stack | Creates |
| --- | --- | --- |
| 1 | `dev-dbxarchitectlab-workspace` | VPC, node subnet, firewall rule, Cloud Router + NAT (plus PSC subnet, endpoints and private DNS zone when `private_service_connect.enabled`), Databricks network configuration, workspace, metastore assignment, admin group assignment |
| 2 | `dev-dbxarchitectlab-workspace-bootstrap` | Unity Catalog GCS bucket, storage credential (Databricks-managed service account) with bucket IAM, external location, catalog, grants, cluster policies, secret scope |

Workspace creation usually takes a few minutes. While it runs, Databricks creates the workspace's GCS root bucket
(`databricks-<workspace-id>` and related buckets) and a compute service account (`db-<workspace-id>@...`) in the
project. The `workspace-bootstrap` stack reads the workspace URL from the `workspace` stack's state, so it must be
applied afterwards.

### 5.3 uat and prod

Repeat 5.2 with the `uat-*` stacks, then the `prod-*` stacks.

## 6. Verify

- Account console → **Workspaces**: the workspace is **Running**; open its URL.
- **Catalog:** the catalog from `catalog-config.yaml` is listed. Each environment's catalog, external location
  and storage credential are bound to that environment's workspace only (`ISOLATED`), so the dev workspace shows
  only `dbxarchitectlab_dev`, uat only `dbxarchitectlab_uat`, and prod only `dbxarchitectlab_prod`, even though they
  share one metastore.
- **Catalog → External data → External locations:** **Test connection** succeeds for the external location.
- **Compute → Policies:** the cluster policies from `cluster-policy-config.yaml` exist.
- **Settings → Identity and access:** `DBX_Architect_Lab_Admin` is a workspace admin.
- GCP console → **VPC network → Firewall:** `db-vpc-dbx-architect-lab-<env>-nodes-ingress` exists.
- Start a small cluster to confirm the network path (Cloud NAT and/or PSC) to the control plane works. Its VMs
  appear under **Compute Engine → VM instances** with no external IP.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `google-github-actions/auth`: `The given credential is rejected by the attribute condition` | The token's claims don't match the provider condition. Compare the **Show OIDC claims** output (`repository_id`, `repository_owner_id`, `environment`) with step 2.4, and check that the job runs in a GitHub environment |
| `Permission 'iam.serviceAccounts.getAccessToken' denied` (auth step or `terragrunt init`) | The `roles/iam.workloadIdentityUser` binding for the pool's `principalSet` is missing or uses the wrong project number / repo ID (step 2.4) |
| `iam.serviceAccounts.getOpenIdToken` denied / **Show runtime identity** fails / Databricks `cannot configure default credentials` | The service account lacks `roles/iam.serviceAccountTokenCreator` on itself (CI) or your user lacks it (local) (step 2.3) |
| `terragrunt init`: `does not have storage.objects.list access to the Google Cloud Storage bucket ... (or it may not exist)` | Authentication worked; the state bucket is the problem. Either it doesn't exist under that exact name (step 2.2; `gcp_project_id` in `live/common.yaml` must be the project **ID**, not its name or number), or the service account has no object access on it: grant `roles/storage.objectAdmin` on the bucket (step 2.3). Also check that the `GCP_DEPLOYER_SERVICE_ACCOUNT` secret is the service account in this project |
| `get_env` error for `DATABRICKS_*` | Secret missing in the GitHub environment the stack runs in |
| Databricks `401` / `User not authorized` / `PERMISSION_DENIED` on `databricks_mws_*` | The service account isn't a user in the Databricks account, or isn't an account admin (step 3.2) |
| `databricks_mws_workspaces`: permission errors on the project, IAM, or service usage | The service account lacks `roles/owner` (or Editor + Project IAM Admin) on the project, or the project's APIs aren't enabled (step 2.1) |
| Workspace creation fails on IAM bindings with a domain / `allowedPolicyMemberDomains` error | An org policy restricts IAM members to your domain. Databricks adds bindings for its own service accounts; allow the Databricks customer ID in the policy or exempt the project |
| `PSC ... requires ENTERPRISE` / private access settings rejected | Account isn't on the Enterprise tier; set `private_service_connect.enabled: false` |
| PSC forwarding rule: service attachment not found / not in region | Wrong `*_service_attachment` for the region (step 1) |
| Cluster fails to start: `Quota 'N2_CPUS' exceeded` / `CPUS` | Raise the region's CPU quotas (step 2.5) or use smaller node types / fewer workers |
| Cluster fails to start: network / bootstrap timeout | The firewall rule `db-<subnet>-ingress` is missing, or there's no egress path (Cloud NAT off and PSC off/misconfigured). With PSC, check the private DNS records in the workspace output (`psc_dns_records`) |
| External location validation fails (`403` on the bucket) | Bucket IAM propagation; re-run `apply`. If it persists, check that `uc_storage_service_account` has `storage.objectAdmin` and `storage.legacyBucketReader` on the bucket |
| `default_labels keys and values must be lowercase...` | `labels` in `live/<env>/config.yaml` don't follow GCP label rules |
| Metastore create fails: region already has a metastore | See step 3.5 |
| Bucket name conflict / name too long | GCS names are global and at most 63 characters; change the `name_prefix` |
| Permission denied creating catalog / external location | The service account isn't a metastore admin (step 3) |
| Workspace group assignment fails: group not found | `DBX_Architect_Lab_Admin` doesn't exist in the account (step 3.3) |

### Destroying

Destroy in reverse order: `*-workspace-bootstrap`, then `*-workspace`, then `metastore`. Deleting a workspace makes
Databricks clean up the resources it created in the project. Check afterwards for leftover `databricks-<workspace-id>*`
buckets and `db-<workspace-id>` service accounts, and remove them manually if they remain.

## Running locally instead

Run as the deployer service account, by impersonation, so local runs behave like CI. Your user needs Token Creator
on it (step 2.3).

```bash
gcloud auth login
gcloud auth application-default login

SA_EMAIL="sa-dbx-platform-infra@<project-id>.iam.gserviceaccount.com"
export GOOGLE_IMPERSONATE_SERVICE_ACCOUNT="$SA_EMAIL"    # google provider and gcs backend act as the service account
export DATABRICKS_GOOGLE_SERVICE_ACCOUNT="$SA_EMAIL"     # Databricks provider impersonates it for Google ID tokens
export DATABRICKS_ACCOUNT_ID="<databricks-account-id>"
export DATABRICKS_METASTORE_ID="<metastore-id>"

cd live/dev/workspace && terragrunt plan
```

On Windows PowerShell:

```powershell
gcloud auth application-default login
$env:GOOGLE_IMPERSONATE_SERVICE_ACCOUNT = "sa-dbx-platform-infra@<project-id>.iam.gserviceaccount.com"
$env:DATABRICKS_GOOGLE_SERVICE_ACCOUNT  = $env:GOOGLE_IMPERSONATE_SERVICE_ACCOUNT
$env:DATABRICKS_ACCOUNT_ID              = "<databricks-account-id>"
$env:DATABRICKS_METASTORE_ID            = "<metastore-id>"
cd live\dev\workspace; terragrunt plan
```

Make sure `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` are **not** set in your shell,
otherwise the Databricks provider picks OAuth instead of Google authentication.

To run `workspace-bootstrap` as your own Databricks user instead of the service account, unset
`DATABRICKS_GOOGLE_SERVICE_ACCOUNT`, run `databricks auth login --host <workspace-url>`, set
`DATABRICKS_AUTH_TYPE=databricks-cli`, and set `DEPLOY_PRINCIPAL` to your Databricks user name (email). Your user
needs the same permissions as the service account (workspace admin, metastore admin). The `workspace` and
`metastore` stacks use the account-level provider, which needs Google authentication as an account admin; the
simplest option is to keep using the service account for them.
