# Deployment guide

How to deploy this repository into a GCP project and a Databricks account on GCP. Deployments normally run
from the GitHub Actions workflow (`.github/workflows/terragrunt-deploy.yml`); they can also run locally (section 9).

This guide reflects the first full rollout (metastore, then dev, uat and prod workspaces and bootstraps). Every
problem found during that rollout is either prevented by the setup script, caught by the pre-flight check, or
listed in **Troubleshooting** with its exact error message.

```
Before you begin  →  1. Repo config  →  2. GCP setup script  →  3. Databricks account  →  4. GitHub
                                                                                            │
     8. Verify  ←  7. Deploy (metastore → dev → uat → prod)  ←  6. Pre-flight check  ←──────┘
```

## Reference values

| Name | Value | Defined in |
| --- | --- | --- |
| GCP project ID | `project-14198bfd-ad7e-4e81-946` | `live/common.yaml` (`gcp_project_id`); per env override in `live/<env>/config.yaml` |
| GCP region | `us-central1` | `live/<env>/config.yaml`, `live/metastore/config.yaml`, `live/common.yaml` (`state.location`) |
| Terraform state bucket | `dbx-architect-lab-tfstate-<project-id>` | `live/common.yaml` + `live/root.hcl` |
| Unity Catalog buckets | `dbx-architect-lab-<env>-uc-<project-id>` | `live/<env>/workspace-bootstrap/gcs-storage-config.yaml` |
| Deployer service account | `sa-dbx-platform-infra@<project-id>.iam.gserviceaccount.com` | `scripts/setup-gcp-prerequisites.sh` |
| Workload Identity pool / provider | `github` / `dbx-platform-infra-gcp` | `scripts/setup-gcp-prerequisites.sh` |
| Databricks account console | <https://accounts.gcp.databricks.com> | |
| Admin group | `DBX_Architect_Lab_Admin` | `live/<env>/config.yaml`, `live/metastore/config.yaml` |
| GitHub repo | `DBxArchitectLab/dbx-platform-infra-gcp` (org ID `336295900`, repo ID `1404588588`) | Workload Identity provider condition |

The Databricks account ID is not stored in the repo (the repo is public). It lives only in the
`DATABRICKS_ACCOUNT_ID` GitHub secret and in the commands you run.

## How authentication works

Databricks on GCP accepts **only Google-issued OIDC tokens** for account-level APIs (creating workspaces,
networks, metastores). So every stack runs as one GCP service account, the **deployer**. No Databricks OAuth
secret is used.

```
GitHub Actions job (environment dev/uat/prod)
   │  GitHub OIDC token
   ▼
Workload Identity Federation (pool "github", provider "dbx-platform-infra-gcp": this repo + environment only)
   │  impersonates
   ▼
Deployer service account ──► Google provider + GCS state backend (project Owner, state bucket object admin)
   │  impersonates itself (Token Creator) to mint Google ID + access tokens
   ▼
Databricks provider ──► account APIs (deployer is a Databricks account admin)
                    └─► workspace APIs (deployer is in DBX_Architect_Lab_Admin → workspace + metastore admin)
```

Each link in this chain was a separate failure point during the first rollout; the pre-flight check (section 6)
tests all of them.

---

## Before you begin: accounts

1. **A GCP project with billing.** Create a project linked to an active billing account. The free trial can work
   for a small lab, but its CPU quotas are low (section 2.2). Each environment has a small fixed cost (Cloud NAT)
   on top of cluster usage.
2. **A Databricks account on GCP.** Subscribe through **Google Cloud Marketplace** (search "Databricks" →
   **Subscribe**, pick the billing account → **Sign up with Databricks**) or at
   <https://www.databricks.com/try-databricks>, choosing Google Cloud. The person who subscribes becomes the first
   **account admin**.
   - This is a **separate account from any Databricks account on AWS or Azure**, with its own account ID.
   - **Premium** works with this repo as configured; **Enterprise** is needed for Private Service Connect.
3. **If the project sits in a GCP Organization**, check these organization policies before you start:
   - `constraints/iam.allowedPolicyMemberDomains` (domain-restricted sharing) can block the IAM bindings for
     Databricks-owned service accounts (workspace creation, Unity Catalog storage credentials).
   - `constraints/gcp.resourceLocations` must allow your region.
   - `constraints/compute.vmExternalIpAccess` is fine: cluster VMs have no public IPs.

### Tools

| Tool | Version | Notes |
| --- | --- | --- |
| Cloud Shell | | Recommended for sections 2, 3 and 6: has `gcloud`, `jq`, `git` and is already signed in |
| Terraform | ≥ 1.10 (CI uses 1.14.6) | Only for local runs |
| Terragrunt | CI uses 0.99.4 | Only for local runs; match the CI version (very old releases such as 0.63 use older CLI flags) |
| Databricks CLI | optional | Only for local runs as your own user |

## 1. Repo configuration

Edit and commit these before the first run.

- [ ] **GCP project.** `gcp_project_id` in `live/common.yaml` must be the project **ID** (not its display name or
      number). All environments use it unless `live/<env>/config.yaml` sets its own `gcp_project_id`; in that
      case, run the setup script (section 2) for that project too.
- [ ] **Region.** Everything defaults to `us-central1`. To change it, update `region` in every
      `live/<env>/config.yaml`, `metastore.region` in `live/metastore/config.yaml`, `state.location` in
      `live/common.yaml`, and the PSC service attachments. The metastore and all workspaces must be in the same
      region.
- [ ] **Names that have length limits:**
  - Databricks account objects on GCP (network configuration, PSC endpoints, private access settings) must match
    `^[a-zA-Z0-9-_]{3,30}$`. The module names them `<prefix>-network`, `<prefix>-ws`, `<prefix>-relay` and
    `<prefix>-pas`, where the prefix is `network.databricks_name_prefix` (default: `vpc_name` without `vpc-`,
    e.g. `dbx-architect-lab-prod`). The prefix must be at most **22** characters; the plan fails early if not.
  - GCS bucket names are at most **63** characters: `<name_prefix>-<project-id>`. With this project ID the longest
    is 56.
- [ ] **CIDRs.** dev, uat and prod use node subnets `10.0.0.0/22`, `10.1.0.0/22` and `10.2.0.0/22` (PSC subnets
      `10.x.4.0/28`). Change them if they overlap with networks you plan to peer with.
- [ ] **Private Service Connect** (`private_service_connect.enabled` in `live/<env>/config.yaml`). Off: it
      requires the **Enterprise** tier. Clusters reach the control plane through Cloud NAT. To turn it on, also
      check `workspace_service_attachment` and `relay_service_attachment` against
      <https://docs.databricks.com/gcp/en/resources/ip-domain-region#psc>.
- [ ] **Grant principals.** `grant_principals` in `catalog-config.yaml` and `external-location-config.yaml`
      (e.g. `dbxarchitectlab@gmail.com`) must exist in the Databricks account (section 3).
- [ ] **Metastore owner.** `metastore.owner` in `live/metastore/config.yaml`: keep `DBX_Architect_Lab_Admin`.
- [ ] **Labels.** `labels` in `live/<env>/config.yaml` become GCP labels: lowercase keys and values, letters,
      digits, `_` and `-` only.

## 2. GCP setup (one script)

`scripts/setup-gcp-prerequisites.sh` does all GCP setup. It is safe to re-run: existing resources are kept,
IAM bindings are only added, and the Workload Identity provider's condition is refreshed.

Open the GCP console, select the project, click **Activate Cloud Shell** (`>_`), and run as a user with
**Owner** on the project:

```bash
git clone https://github.com/DBxArchitectLab/dbx-platform-infra-gcp.git
cd dbx-platform-infra-gcp
PROJECT_ID="project-14198bfd-ad7e-4e81-946" bash scripts/setup-gcp-prerequisites.sh
```

### 2.1 What the script does

| Step | What | Why |
| --- | --- | --- |
| 1 | Enables `compute`, `storage`, `iam`, `iamcredentials`, `sts`, `cloudresourcemanager`, `serviceusage`, `dns` | `iamcredentials`/`sts` for Workload Identity and impersonation; `dns` only for PSC. Databricks enables anything else it needs |
| 2 | Creates `gs://dbx-architect-lab-tfstate-<project-id>` (uniform access, public access prevention, versioning) | Terraform state. The GCS backend locks natively |
| 3 | Creates `sa-dbx-platform-infra` | The deployer identity |
| 4a | Grants the deployer `roles/owner` on the project | Creates the VPC, NAT, firewall and buckets. Databricks also uses the creator's permissions to set up each workspace (service account, custom roles, IAM bindings) |
| 4b | Grants the deployer `roles/storage.objectAdmin` **on the state bucket** | Project Owner doesn't reliably grant object access on a uniform-access bucket; without this `terragrunt init` fails |
| 4c | Grants `roles/iam.serviceAccountTokenCreator` on the deployer to **itself** and to **you** | The Databricks provider mints Google tokens by impersonating the deployer, in CI (itself) and locally/pre-flight (you) |
| 5 | Creates the Workload Identity pool `github` and provider `dbx-platform-infra-gcp`, and grants the repo `roles/iam.workloadIdentityUser` on the deployer | Keyless GitHub Actions auth, limited to this repo (`repository_id 1404588588`, org `336295900`) and its `dev`, `uat`, `prod` environments |
| 6 | Prints the two GitHub secret values | Used in section 4 |

**Least privilege.** `roles/owner` keeps a lab simple. For production, run the script with
`SA_PROJECT_ROLES="roles/editor roles/resourcemanager.projectIamAdmin roles/storage.admin roles/dns.admin"`.
Editor + Project IAM Admin is the minimum Databricks documents for workspace creation; Storage Admin lets
Terraform set bucket IAM for Unity Catalog; DNS Admin is only needed with PSC.

### 2.2 CPU quota

Databricks clusters on GCP use N2 machines, and new projects often have a low `N2_CPUS` / `CPUS` quota per
region. The sample clusters in `cluster-config.yaml` can need up to ~80 vCPUs each at full autoscale. The
pre-flight check prints current usage and limits; request increases under **IAM & Admin → Quotas & System
Limits**.

## 3. Databricks account

In the account console <https://accounts.gcp.databricks.com>, signed in as an account admin:

1. **Copy the account ID** from the user menu (top right). It goes into the `DATABRICKS_ACCOUNT_ID` secret. Use the
   ID of the **GCP** account: an ID from a Databricks account on another cloud returns `401 Invalid Request`.
2. **Add the deployer service account as an account admin.** This replaces the Databricks service principal +
   OAuth secret used on other clouds; there is no secret to generate.
   1. **User management → Users → Add user**. Email: `sa-dbx-platform-infra@<project-id>.iam.gserviceaccount.com`
      (exactly as printed by the setup script). First/last name: anything, e.g. `sa-dbx` / `platform-infra`.
   2. Open the user → **Roles** tab → turn on **Account admin**.

   Until both are done, every Databricks call fails with `403 Invalid Request` (in Terraform:
   `cannot create metastore: Invalid Request`).
3. **Create the group `DBX_Architect_Lab_Admin`** (**User management → Groups**) and add the deployer service
   account and your own user. The workspace stack makes this group workspace admin, and the metastore stack makes
   it metastore owner. That is how the deployer gets the rights the bootstrap stack needs.
4. **Add the users** named in the `grant_principals` lists (**User management → Users**).
5. **Existing metastore?** An account can have only one metastore per region. The pre-flight check lists any
   metastore in `us-central1`. If one exists, either use it (skip the metastore stack, put its ID in
   `DATABRICKS_METASTORE_ID`, make `DBX_Architect_Lab_Admin` its owner under **Catalog → metastore → Edit**) or
   delete it if nothing uses it.

## 4. GitHub setup

1. **Merge to `main`.** A manually started workflow only appears under **Actions** once it is on the default
   branch. (Runs can then target any branch with the **Use workflow from** selector.)
2. **Create environments** under **Settings → Environments**: `dev`, `uat`, `prod`. The names must match the
   Workload Identity provider condition. Consider required reviewers on `prod`.
3. **Add these secrets to each of the three environments** (same values in all three):

   | Secret | Value |
   | --- | --- |
   | `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/<project-number>/locations/global/workloadIdentityPools/github/providers/dbx-platform-infra-gcp` (printed by the setup script) |
   | `GCP_DEPLOYER_SERVICE_ACCOUNT` | `sa-dbx-platform-infra@<project-id>.iam.gserviceaccount.com` (printed by the setup script) |
   | `DATABRICKS_ACCOUNT_ID` | the GCP Databricks account ID (section 3.1) |
   | `DATABRICKS_METASTORE_ID` | metastore ID; any placeholder until section 7.1 |

   The `metastore` stack runs in the `dev` environment. The workflow passes `GCP_DEPLOYER_SERVICE_ACCOUNT` to
   Terraform as `DATABRICKS_GOOGLE_SERVICE_ACCOUNT`, which is also the principal added to the catalog and external
   location grants.

## 5. Re-running after a failure

Every stack is safe to re-apply. Resources created before a failure are in Terraform state; the next `apply`
keeps them and continues where it stopped. After fixing a cause, push the fix (if any) and re-run the same stack
with `apply`. Nothing needs to be cleaned up by hand.

## 6. Pre-flight check

Run this before the first deployment, and whenever a run fails with a permission or `Invalid Request` error. It
is read-only and prints the fix for each failure. In Cloud Shell, from the repo directory:

```bash
PROJECT_ID="project-14198bfd-ad7e-4e81-946" \
DBX_ACCOUNT_ID="<databricks-account-id>" \
bash scripts/preflight-check.sh
```

| Check | Catches (error you would otherwise get) |
| --- | --- |
| Project ID resolves | Wrong `gcp_project_id` (state bucket "may not exist") |
| Required APIs enabled | API errors during the workspace stack |
| State bucket exists, deployer has object access | `terragrunt init`: `does not have storage.objects.list access` |
| Deployer has Owner (or Editor + Project IAM Admin) | Workspace stack: `Required 'compute.networks.create' permission` |
| Deployer has Token Creator on itself | Databricks provider: `getOpenIdToken` denied / `cannot configure default credentials` |
| Workload Identity provider + repo binding | CI auth: `rejected by the attribute condition` / `getAccessToken` denied |
| You can impersonate the deployer | Local runs and the remaining checks |
| Databricks account API answers (401 / 403 decoded) | `cannot create metastore: Invalid Request` and any `databricks_mws_*` error |
| Existing metastore in the region | Metastore stack: region already has a metastore |
| Admin group exists and contains the deployer | Workspace stack: group not found; bootstrap permission errors |
| CPU quota | Clusters failing to start |

Expected result: `All checks passed.`, plus INFO lines with the two GitHub secret values, any existing metastore,
and CPU quota.

## 7. Deploy

Go to **Actions → Terragrunt Deploy Stacks → Run workflow**, choose a **stack** and an **action**. For each stack,
run `plan`, review the log, then `apply`.

### 7.1 Metastore (once per region)

| Stack | Creates |
| --- | --- |
| `metastore` | Unity Catalog metastore `metastore-dbx-architect-lab` in `us-central1`, owned by `DBX_Architect_Lab_Admin` |

Copy `metastore_id` from the end of the apply log (or **Catalog** in the account console) into the
`DATABRICKS_METASTORE_ID` secret of **all three** environments. They share the metastore.

### 7.2 dev, then uat, then prod

For each environment, in this order:

| Order | Stack | Creates | Duration |
| --- | --- | --- | --- |
| 1 | `<env>-dbxarchitectlab-workspace` | VPC, node subnet, firewall rule `db-<subnet>-ingress`, Cloud Router + NAT (plus PSC subnet, endpoints and private DNS zone if enabled), Databricks network configuration, workspace, metastore assignment, admin group assignment | ~5–10 min |
| 2 | `<env>-dbxarchitectlab-workspace-bootstrap` | Unity Catalog GCS bucket, storage credential with bucket IAM, external location, catalog (all isolated to this environment's workspace), grants, cluster policies, secret scope | ~3–5 min |

While the workspace is created, Databricks itself creates the workspace's GCS buckets (`databricks-<workspace-id>*`)
and a compute service account (`db-<workspace-id>@...`) in the project; they are not in Terraform state.

The bootstrap includes two deliberate waits:

- **90 s** after creating the storage credential. Databricks creates the credential's service account
  (`db-uc-credential-...@uc-<region>.iam.gserviceaccount.com`) in its own project, and GCP IAM needs time
  before it accepts bucket bindings for it.
- **30 s** after the bucket bindings, before creating the external location (which validates access).

The bootstrap reads the workspace URL from the workspace stack's state, so it must run after it.

## 8. Verify

For each environment:

- Account console → **Workspaces**: the workspace is **Running**; open its URL.
- **Catalog**: only that environment's catalog is visible (`dbxarchitectlab_dev`, `_uat` or `_prod`). The
  catalog, external location and storage credential are bound to their own workspace (`ISOLATED`) even though the
  metastore is shared.
- **Catalog → External data → External locations**: **Test connection** succeeds.
- **Compute → Policies**: `shared_compute_customize` exists.
- **Settings → Identity and access**: `DBX_Architect_Lab_Admin` is a workspace admin.
- GCP console → **VPC network → Firewall**: `db-vpc-dbx-architect-lab-<env>-nodes-ingress` exists.
- Start a small cluster. Its VMs appear under **Compute Engine → VM instances** with no external IP, which
  confirms the Cloud NAT (or PSC) path to the control plane.

## Troubleshooting

Start with the pre-flight check (section 6): it pinpoints most of these. Rows marked ✔ happened during the first
rollout; their fixes are now built into the code, the setup script, or the check.

### GitHub Actions authentication

| Symptom | Cause and fix |
| --- | --- |
| `google-github-actions/auth`: `The given credential is rejected by the attribute condition` | Token claims don't match the provider condition. The pre-flight check prints the condition: it requires org ID `336295900`, repo ID `1404588588` and a `dev`/`uat`/`prod` environment. Make sure the job runs in one of those GitHub environments |
| `Permission 'iam.serviceAccounts.getAccessToken' denied` | Missing `roles/iam.workloadIdentityUser` binding for the repo, or a wrong project number in `GCP_WORKLOAD_IDENTITY_PROVIDER`. Re-run the setup script |
| `iam.serviceAccounts.getOpenIdToken` denied / Databricks `cannot configure default credentials` | Deployer lacks Token Creator on itself. Re-run the setup script |
| `get_env` error for `DATABRICKS_*` | Secret missing in the GitHub environment the stack runs in |

### Terraform state

| Symptom | Cause and fix |
| --- | --- |
| ✔ `terragrunt init`: `does not have storage.objects.list access to the Google Cloud Storage bucket ... (or it may not exist)` | Authentication worked; the bucket is the problem. Either it doesn't exist under that exact name (`gcp_project_id` must be the project **ID**), or the deployer has no object access on it. The setup script now grants `roles/storage.objectAdmin` on the bucket. Also check `GCP_DEPLOYER_SERVICE_ACCOUNT` is the account in this project |

### Databricks account

The account API returns the same text, `Invalid Request`, for different problems; the HTTP code tells them apart.
Terraform shows only the text, so run the pre-flight check (or the script below) to see the code.

| Symptom | Cause and fix |
| --- | --- |
| ✔ `401 Invalid Request` | The account ID isn't a Databricks-on-GCP account ID: a placeholder, a typo, or the ID of an account on another cloud. Copy it from <https://accounts.gcp.databricks.com> and set it in all three environments |
| ✔ `403 Invalid Request` / Terraform `cannot create metastore: Invalid Request` / errors on `databricks_mws_*` | The deployer isn't a user in the account, or isn't an account admin (section 3.2). Check the email matches the service account exactly |
| Metastore create fails: region already has a metastore | Use or delete the existing one (section 3.5) |
| Workspace group assignment fails: group not found | `DBX_Architect_Lab_Admin` doesn't exist (section 3.3) |
| Permission denied creating catalog / external location / storage credential | Deployer isn't a metastore admin: it must be in `DBX_Architect_Lab_Admin`, and that group must own the metastore |

To see the full response of an account API call, run in Cloud Shell:

```bash
ACC="https://accounts.gcp.databricks.com"
DBX_ACCOUNT_ID="<databricks-account-id>"
SA_EMAIL="sa-dbx-platform-infra@project-14198bfd-ad7e-4e81-946.iam.gserviceaccount.com"

ID_TOKEN=$(gcloud auth print-identity-token --impersonate-service-account="$SA_EMAIL" --audiences="$ACC" --include-email 2>/dev/null)
ACCESS_TOKEN=$(gcloud auth print-access-token --impersonate-service-account="$SA_EMAIL" 2>/dev/null)
H=(-H "Authorization: Bearer $ID_TOKEN" -H "X-Databricks-GCP-SA-Access-Token: $ACCESS_TOKEN")

curl -s "${H[@]}" "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/metastores" | jq .
curl -s "${H[@]}" "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/workspaces" | jq '.[] | {workspace_name, workspace_id, workspace_status}'
```

### Workspace stack

| Symptom | Cause and fix |
| --- | --- |
| ✔ `Error creating Network: ... Required 'compute.networks.create' permission` | The deployer has no project role (the Owner grant was missing). The setup script grants it; the pre-flight check verifies it. Wait 1–2 minutes after granting before re-running |
| ✔ `cannot create mws networks: Malformed parameters: network_name ... is not of the form ^[a-zA-Z0-9-_]{3,30}$` | Databricks names on GCP are limited to 30 characters. Fixed in the module (short `databricks_name_prefix`); an over-long prefix now fails at plan time |
| `databricks_mws_workspaces`: permission errors on the project, IAM, or service usage | Deployer lacks Owner (or Editor + Project IAM Admin), or APIs aren't enabled. Re-run the setup script |
| Workspace creation fails with an `allowedPolicyMemberDomains` error | Organization policy restricts IAM members to your domain; allow the Databricks customer ID in the policy or exempt the project |
| ✔ Destroy: `cannot delete mws networks: MALFORMED_REQUEST: Cannot delete a network while it is attached to a workspace` | Databricks deletes a GCP workspace in the background, and its network stays attached for several minutes. The stack now waits 10 minutes between the two on destroy. A workspace stack deployed before that wait was added has no wait in state: run `apply` on it once before `destroy`, or simply re-run `destroy` a few minutes after this error (the workspace is already gone from state, so it continues with the network) |
| `PSC ... requires ENTERPRISE` / private access settings rejected | Account isn't on Enterprise; set `private_service_connect.enabled: false` |
| PSC forwarding rule: service attachment not found | Wrong `*_service_attachment` for the region |

### Workspace bootstrap stack

| Symptom | Cause and fix |
| --- | --- |
| ✔ `Error setting IAM policy for storage bucket ...: Service account db-uc-credential-...@uc-<region>.iam.gserviceaccount.com does not exist` | The Databricks-created credential service account wasn't visible to GCP IAM yet. The module now waits 90 s first; if it still happens, re-run `apply` (only the bindings are retried) |
| External location validation fails (`403` on the bucket) | Bucket IAM propagation; re-run `apply`. If it persists, check that `uc_storage_service_account` (stack output) has `storage.objectAdmin` and `storage.legacyBucketReader` on the bucket |
| `default_labels keys and values must be lowercase...` | `labels` in `live/<env>/config.yaml` break GCP label rules |
| Bucket name conflict / too long | GCS names are global and at most 63 characters; change `name_prefix` |
| Re-bind script prints `HTTP 000` | `curl` couldn't connect: the workspace URL is wrong. The number after the workspace ID (`<id>.<n>.gcp.databricks.com`) differs per workspace; copy the URL from the account console instead of guessing |
| ✔ Destroy: `cannot delete grants: Catalog '...' (or External Location '...') is not accessible in current workspace` | An earlier version created explicit workspace bindings, and `destroy` removed them before the grants, leaving the objects inaccessible. Fixed: new deployments rely on the automatic binding to the creating workspace. A stack deployed with the old version still has bindings in state, and `destroy` ignores the `removed` blocks that drop them, so: (1) re-bind the objects (script below), (2) run `apply` on the bootstrap stack once (drops the bindings from state without unbinding), (3) run `destroy` |

To re-bind an environment's isolated objects to its workspace (for example after the destroy error above), run in
Cloud Shell with the workspace URL and ID from the account console (**Workspaces**). Re-running it is harmless; an
object that was already deleted reports not found:

```bash
WS_URL="https://<workspace-id>.<n>.gcp.databricks.com"   # copy from the console: <n> differs per workspace; no trailing /
WS_ID="<workspace-id>"
ENV="dev"
SA_EMAIL="sa-dbx-platform-infra@project-14198bfd-ad7e-4e81-946.iam.gserviceaccount.com"

ID_TOKEN=$(gcloud auth print-identity-token --impersonate-service-account="$SA_EMAIL" --audiences="$WS_URL" --include-email 2>/dev/null)
ACCESS_TOKEN=$(gcloud auth print-access-token --impersonate-service-account="$SA_EMAIL" 2>/dev/null)
H=(-H "Authorization: Bearer $ID_TOKEN" -H "X-Databricks-GCP-SA-Access-Token: $ACCESS_TOKEN")
BODY="{\"add\": [{\"workspace_id\": $WS_ID, \"binding_type\": \"BINDING_TYPE_READ_WRITE\"}]}"

for S in "catalog dbxarchitectlab_$ENV"          "external_location ext_loc_dbx_architect_lab_$ENV"          "storage_credential ext_loc_dbx_architect_lab_${ENV}_cred"; do
  set -- $S
  echo "== $1 $2"
  curl -s "${H[@]}" -X PATCH "$WS_URL/api/2.1/unity-catalog/bindings/$1/$2" -d "$BODY" | jq -c .
done
```

### Clusters

| Symptom | Cause and fix |
| --- | --- |
| `Quota 'N2_CPUS' exceeded` / `CPUS` | Raise the region's CPU quota (section 2.2) or use smaller node types / fewer workers |
| Network or bootstrap timeout | Firewall rule `db-<subnet>-ingress` missing, or no egress path (Cloud NAT off and PSC off or misconfigured). With PSC, check the `psc_dns_records` output of the workspace stack |

## Destroying

Destroy in reverse order with the workflow's `destroy` action (a workspace stack takes 10+ minutes: it waits for Databricks to finish deleting the workspace before deleting its network): `<env>-dbxarchitectlab-workspace-bootstrap`, then
`<env>-dbxarchitectlab-workspace` (for each environment), then `metastore`. Deleting a workspace makes Databricks
clean up the resources it created in the project; check afterwards for leftover `databricks-<workspace-id>*`
buckets and `db-<workspace-id>` service accounts and remove them if they remain. The state bucket, deployer
service account and Workload Identity pool are not managed by Terraform; delete them by hand if you retire the
project.

## 9. Running locally

Run as the deployer by impersonation, so local runs behave like CI. Your user needs Token Creator on the deployer
(the setup script grants it to whoever runs it).

```bash
gcloud auth login
gcloud auth application-default login

SA_EMAIL="sa-dbx-platform-infra@project-14198bfd-ad7e-4e81-946.iam.gserviceaccount.com"
export GOOGLE_IMPERSONATE_SERVICE_ACCOUNT="$SA_EMAIL"    # Google provider and GCS backend act as the deployer
export DATABRICKS_GOOGLE_SERVICE_ACCOUNT="$SA_EMAIL"     # Databricks provider impersonates it for Google tokens
export DATABRICKS_ACCOUNT_ID="<databricks-account-id>"
export DATABRICKS_METASTORE_ID="<metastore-id>"

cd live/dev/workspace && terragrunt plan
```

Windows PowerShell:

```powershell
gcloud auth application-default login
$env:GOOGLE_IMPERSONATE_SERVICE_ACCOUNT = "sa-dbx-platform-infra@project-14198bfd-ad7e-4e81-946.iam.gserviceaccount.com"
$env:DATABRICKS_GOOGLE_SERVICE_ACCOUNT  = $env:GOOGLE_IMPERSONATE_SERVICE_ACCOUNT
$env:DATABRICKS_ACCOUNT_ID              = "<databricks-account-id>"
$env:DATABRICKS_METASTORE_ID            = "<metastore-id>"
cd live\dev\workspace; terragrunt plan
```

Make sure `DATABRICKS_CLIENT_ID` / `DATABRICKS_CLIENT_SECRET` are **not** set in your shell; otherwise the
Databricks provider uses OAuth instead of Google authentication.

To run `workspace-bootstrap` as your own Databricks user instead, unset `DATABRICKS_GOOGLE_SERVICE_ACCOUNT`, run
`databricks auth login --host <workspace-url>`, set `DATABRICKS_AUTH_TYPE=databricks-cli`, and set
`DEPLOY_PRINCIPAL` to your Databricks user name (email). Your user needs the same rights as the deployer
(workspace admin, metastore admin). The `workspace` and `metastore` stacks need Google authentication as an
account admin; keep using the deployer for them.
