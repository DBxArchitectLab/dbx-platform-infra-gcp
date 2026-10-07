#!/usr/bin/env bash
# One-time GCP prerequisites for dbx-platform-infra-gcp (DEPLOYMENT.md step 2).
#
# Creates or updates: required APIs, the Terraform state bucket, the deployer service account and its roles,
# and Workload Identity Federation for GitHub Actions. Safe to re-run: existing resources are kept and IAM
# bindings are only added.
#
# Run in Cloud Shell (or anywhere gcloud is signed in) as a user with Owner on the project:
#   PROJECT_ID="<project-id>" bash scripts/setup-gcp-prerequisites.sh
#
# Optional overrides (environment variables):
#   REGION            default us-central1
#   SA_NAME           default sa-dbx-platform-infra
#   STATE_BUCKET      default dbx-architect-lab-tfstate-<PROJECT_ID>
#   GH_ORG_ID         default 336295900   (DBxArchitectLab)
#   GH_REPO_ID        default 1404588588  (DBxArchitectLab/dbx-platform-infra-gcp)
#   WIF_POOL          default github
#   WIF_PROVIDER      default dbx-platform-infra-gcp
#   SA_PROJECT_ROLES  default "roles/owner"; least privilege:
#                     "roles/editor roles/resourcemanager.projectIamAdmin roles/storage.admin roles/dns.admin"
set -euo pipefail

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID to the GCP project ID (same as gcp_project_id in live/common.yaml)}"
REGION="${REGION:-us-central1}"
SA_NAME="${SA_NAME:-sa-dbx-platform-infra}"
STATE_BUCKET="${STATE_BUCKET:-dbx-architect-lab-tfstate-$PROJECT_ID}"
GH_ORG_ID="${GH_ORG_ID:-336295900}"
GH_REPO_ID="${GH_REPO_ID:-1404588588}"
WIF_POOL="${WIF_POOL:-github}"
WIF_PROVIDER="${WIF_PROVIDER:-dbx-platform-infra-gcp}"
SA_PROJECT_ROLES="${SA_PROJECT_ROLES:-roles/owner}"

SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

step() { echo; echo "== $*"; }

gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
# Fails fast if PROJECT_ID is a project name or number instead of the ID.
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
ME=$(gcloud config get-value account 2>/dev/null)
echo "Project $PROJECT_ID (number $PROJECT_NUMBER), running as $ME"

step "1/6 Enable APIs"
gcloud services enable \
  compute.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  dns.googleapis.com
echo "enabled"

step "2/6 Terraform state bucket gs://$STATE_BUCKET"
if gcloud storage buckets describe "gs://$STATE_BUCKET" >/dev/null 2>&1; then
  echo "exists"
else
  gcloud storage buckets create "gs://$STATE_BUCKET" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi
gcloud storage buckets update "gs://$STATE_BUCKET" --versioning >/dev/null
echo "versioning on"

step "3/6 Deployer service account $SA_EMAIL"
if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  echo "exists"
else
  gcloud iam service-accounts create "$SA_NAME" --display-name="Databricks platform infra deployer"
  # A new service account can take a few seconds before IAM accepts bindings for it.
  sleep 20
fi

step "4/6 Roles for the deployer service account"
# Project roles: create the VPC/NAT/firewall/buckets, and let Databricks set up each workspace (it creates a
# service account, custom roles and IAM bindings in the project with the creator's permissions).
for ROLE in $SA_PROJECT_ROLES; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$SA_EMAIL" --role="$ROLE" --condition=None >/dev/null
  echo "project: $ROLE"
done

# Explicit object access on the state bucket. Project basic roles don't reliably grant it on a bucket with
# uniform bucket-level access ("does not have storage.objects.list access" in terragrunt init).
gcloud storage buckets add-iam-policy-binding "gs://$STATE_BUCKET" \
  --member="serviceAccount:$SA_EMAIL" --role="roles/storage.objectAdmin" >/dev/null
echo "state bucket: roles/storage.objectAdmin"

# The Databricks provider mints Google ID/access tokens for the service account by impersonation: the service
# account impersonates itself in CI, and you impersonate it for local runs and the pre-flight check.
for MEMBER in "serviceAccount:$SA_EMAIL" "user:$ME"; do
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --member="$MEMBER" --role="roles/iam.serviceAccountTokenCreator" >/dev/null
  echo "token creator: $MEMBER"
done

step "5/6 Workload Identity Federation (pool $WIF_POOL, provider $WIF_PROVIDER)"
if gcloud iam workload-identity-pools describe "$WIF_POOL" --location=global >/dev/null 2>&1; then
  echo "pool exists"
else
  gcloud iam workload-identity-pools create "$WIF_POOL" --location=global --display-name="GitHub Actions"
fi

# Only this repo, and only jobs running in its dev/uat/prod GitHub environments, can get credentials.
CONDITION="assertion.repository_owner_id == '${GH_ORG_ID}' && assertion.repository_id == '${GH_REPO_ID}' && assertion.environment in ['dev', 'uat', 'prod']"
MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_id=assertion.repository_id,attribute.environment=assertion.environment"
if gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
  --location=global --workload-identity-pool="$WIF_POOL" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers update-oidc "$WIF_PROVIDER" \
    --location=global --workload-identity-pool="$WIF_POOL" \
    --attribute-mapping="$MAPPING" --attribute-condition="$CONDITION" >/dev/null
  echo "provider exists (mapping and condition refreshed)"
else
  gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
    --location=global --workload-identity-pool="$WIF_POOL" \
    --display-name="$WIF_PROVIDER" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$MAPPING" --attribute-condition="$CONDITION"
fi

gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository_id/${GH_REPO_ID}" >/dev/null
echo "workload identity user: repo $GH_REPO_ID"

step "6/6 Done. GitHub environment secrets (dev, uat, prod):"
echo "  GCP_WORKLOAD_IDENTITY_PROVIDER = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"
echo "  GCP_DEPLOYER_SERVICE_ACCOUNT   = $SA_EMAIL"
echo
echo "Next: add $SA_EMAIL to the Databricks account as an account admin (DEPLOYMENT.md step 3),"
echo "then run scripts/preflight-check.sh."
