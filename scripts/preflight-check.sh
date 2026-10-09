#!/usr/bin/env bash
# Read-only pre-flight check for dbx-platform-infra-gcp (DEPLOYMENT.md section 6). Changes nothing.
#
# Verifies every prerequisite the stacks depend on and prints the fix for each failure: the GCP project, APIs,
# state bucket, deployer service account roles, impersonation, Workload Identity Federation, the Databricks
# account (ID, account admin), the admin group, an existing metastore in the region, and CPU quota.
#
# Run in Cloud Shell as a user who can impersonate the deployer service account (setup-gcp-prerequisites.sh
# grants this to the user who ran it):
#   PROJECT_ID="<project-id>" DBX_ACCOUNT_ID="<databricks-account-id>" bash scripts/preflight-check.sh
#
# Optional overrides: REGION, SA_NAME, STATE_BUCKET, GH_REPO_ID, WIF_POOL, WIF_PROVIDER, ADMIN_GROUP
set -uo pipefail

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID to the GCP project ID (same as gcp_project_id in live/common.yaml)}"
DBX_ACCOUNT_ID="${DBX_ACCOUNT_ID:?Set DBX_ACCOUNT_ID to the Databricks account ID from https://accounts.gcp.databricks.com}"
REGION="${REGION:-us-central1}"
SA_NAME="${SA_NAME:-sa-dbx-platform-infra}"
STATE_BUCKET="${STATE_BUCKET:-dbx-architect-lab-tfstate-$PROJECT_ID}"
GH_REPO_ID="${GH_REPO_ID:-1404588588}"
WIF_POOL="${WIF_POOL:-github}"
WIF_PROVIDER="${WIF_PROVIDER:-dbx-platform-infra-gcp}"
ADMIN_GROUP="${ADMIN_GROUP:-DBX_Architect_Lab_Admin}"

SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
ACC="https://accounts.gcp.databricks.com"
FAILURES=0

pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $1"; echo "        fix: $2"; FAILURES=$((FAILURES + 1)); }
info() { echo "  INFO  $*"; }
section() { echo; echo "== $*"; }

section "GCP project"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null)
if [ -n "$PROJECT_NUMBER" ]; then
  pass "project $PROJECT_ID (number $PROJECT_NUMBER)"
else
  fail "project $PROJECT_ID not found or not accessible" \
    "use the project ID (not its name or number) here and in live/common.yaml"
  echo; echo "Stopping: the remaining checks need the project."; exit 1
fi

ENABLED=$(gcloud services list --enabled --project="$PROJECT_ID" --format='value(config.name)' 2>/dev/null)
for API in compute storage iam iamcredentials sts cloudresourcemanager serviceusage; do
  if grep -qx "$API.googleapis.com" <<<"$ENABLED"; then pass "API $API"; else
    fail "API $API.googleapis.com not enabled" "re-run scripts/setup-gcp-prerequisites.sh (DEPLOYMENT.md section 2)"; fi
done

section "Terraform state bucket"
if gcloud storage buckets describe "gs://$STATE_BUCKET" >/dev/null 2>&1; then
  pass "gs://$STATE_BUCKET exists"
  if gcloud storage buckets get-iam-policy "gs://$STATE_BUCKET" --format=json 2>/dev/null \
    | jq -e --arg m "serviceAccount:$SA_EMAIL" '.bindings[]? | select(.role=="roles/storage.objectAdmin") | .members[] | select(.==$m)' >/dev/null; then
    pass "deployer has roles/storage.objectAdmin on the bucket"
  else
    fail "deployer has no object access on the state bucket (terragrunt init: storage.objects.list denied)" \
      "re-run scripts/setup-gcp-prerequisites.sh (DEPLOYMENT.md section 2)"
  fi
else
  fail "gs://$STATE_BUCKET missing (terragrunt init: storage.objects.list denied ... or it may not exist)" \
    "re-run scripts/setup-gcp-prerequisites.sh (DEPLOYMENT.md section 2)"
fi

section "Deployer service account $SA_EMAIL"
if gcloud iam service-accounts describe "$SA_EMAIL" >/dev/null 2>&1; then
  pass "exists"
else
  fail "service account missing" "run scripts/setup-gcp-prerequisites.sh (DEPLOYMENT.md section 2)"
fi

ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" --flatten=bindings \
  --filter="bindings.members:serviceAccount:$SA_EMAIL" --format='value(bindings.role)' 2>/dev/null)
if grep -qx "roles/owner" <<<"$ROLES" || { grep -qx "roles/editor" <<<"$ROLES" && grep -qx "roles/resourcemanager.projectIamAdmin" <<<"$ROLES"; }; then
  pass "project roles: $(echo $ROLES)"
else
  fail "no roles/owner (or editor + projectIamAdmin) on the project (workspace stack: compute.networks.create denied)" \
    "re-run scripts/setup-gcp-prerequisites.sh (DEPLOYMENT.md section 2); found: ${ROLES:-none}"
fi

SA_POLICY=$(gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --format=json 2>/dev/null)
if jq -e --arg m "serviceAccount:$SA_EMAIL" '.bindings[]? | select(.role=="roles/iam.serviceAccountTokenCreator") | .members[] | select(.==$m)' <<<"$SA_POLICY" >/dev/null; then
  pass "can impersonate itself (Token Creator)"
else
  fail "missing Token Creator on itself (CI: Show runtime identity / getOpenIdToken denied)" \
    "re-run scripts/setup-gcp-prerequisites.sh (DEPLOYMENT.md section 2)"
fi

section "Workload Identity Federation"
CONDITION=$(gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" --location=global \
  --workload-identity-pool="$WIF_POOL" --format='value(attributeCondition)' 2>/dev/null)
if [ -n "$CONDITION" ]; then
  pass "provider $WIF_POOL/$WIF_PROVIDER"
  info "condition: $CONDITION"
else
  fail "provider $WIF_POOL/$WIF_PROVIDER missing" "re-run scripts/setup-gcp-prerequisites.sh (DEPLOYMENT.md section 2)"
fi
if jq -e --arg r "/attribute.repository_id/$GH_REPO_ID" '.bindings[]? | select(.role=="roles/iam.workloadIdentityUser") | .members[] | select(endswith($r))' <<<"$SA_POLICY" >/dev/null; then
  pass "repo $GH_REPO_ID can impersonate the deployer"
else
  fail "no workloadIdentityUser binding for repo $GH_REPO_ID (CI auth: iam.serviceAccounts.getAccessToken denied)" \
    "re-run scripts/setup-gcp-prerequisites.sh (DEPLOYMENT.md section 2)"
fi
info "GCP_WORKLOAD_IDENTITY_PROVIDER = projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$WIF_POOL/providers/$WIF_PROVIDER"
info "GCP_DEPLOYER_SERVICE_ACCOUNT   = $SA_EMAIL"

section "Impersonation (what the Databricks provider does)"
ID_TOKEN=$(gcloud auth print-identity-token --impersonate-service-account="$SA_EMAIL" --audiences="$ACC" --include-email 2>/dev/null)
ACCESS_TOKEN=$(gcloud auth print-access-token --impersonate-service-account="$SA_EMAIL" 2>/dev/null)
if [ -n "$ID_TOKEN" ] && [ -n "$ACCESS_TOKEN" ]; then
  pass "Google ID and access tokens issued for $SA_EMAIL"
else
  fail "cannot impersonate $SA_EMAIL as $(gcloud config get-value account 2>/dev/null)" \
    "grant your user roles/iam.serviceAccountTokenCreator on the service account (setup script does this for the user who runs it)"
  echo; echo "Stopping: the Databricks checks need the tokens. $FAILURES failure(s)."; exit 1
fi
H=(-H "Authorization: Bearer $ID_TOKEN" -H "X-Databricks-GCP-SA-Access-Token: $ACCESS_TOKEN")

section "Databricks account $DBX_ACCOUNT_ID"
METASTORES=$(curl -s "${H[@]}" "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/metastores")
CODE=$(jq -r '.error_code // empty' <<<"$METASTORES" 2>/dev/null)
case "$CODE" in
  "")
    pass "deployer is an account admin"
    REGIONAL=$(jq -r --arg r "$REGION" '.metastores[]? | select(.region==$r) | "\(.name)  \(.metastore_id)  owner=\(.owner)"' <<<"$METASTORES")
    if [ -n "$REGIONAL" ]; then
      info "metastore already in $REGION: $REGIONAL"
      info "  → skip the metastore stack; use this metastore_id as DATABRICKS_METASTORE_ID and make $ADMIN_GROUP its owner"
    else
      info "no metastore in $REGION yet → deploy the metastore stack first"
    fi
    ;;
  401)
    fail "401 Invalid Request: account $DBX_ACCOUNT_ID not recognized" \
      "copy the account ID from https://accounts.gcp.databricks.com (user menu); an account on another cloud has a different ID"
    ;;
  403)
    fail "403 Invalid Request: $SA_EMAIL is not a user or not an account admin in this account" \
      "account console → User management → Users → Add user ($SA_EMAIL) → Roles → Account admin (DEPLOYMENT.md section 3)"
    ;;
  *)
    fail "unexpected response: $(jq -c . <<<"$METASTORES" 2>/dev/null || echo "$METASTORES")" "see Troubleshooting in DEPLOYMENT.md"
    ;;
esac

if [ -z "$CODE" ]; then
  SA_ID=$(curl -s -G "${H[@]}" --data-urlencode "filter=userName eq \"$SA_EMAIL\"" \
    "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/scim/v2/Users" | jq -r '.Resources[0].id // empty')
  GROUP=$(curl -s -G "${H[@]}" --data-urlencode "filter=displayName eq \"$ADMIN_GROUP\"" \
    "$ACC/api/2.0/accounts/$DBX_ACCOUNT_ID/scim/v2/Groups" | jq '.Resources[0] // empty')
  if [ -z "$GROUP" ]; then
    fail "group $ADMIN_GROUP missing (workspace stack: group not found)" \
      "account console → User management → Groups → create $ADMIN_GROUP (DEPLOYMENT.md section 3)"
  elif [ -n "$SA_ID" ] && jq -e --arg id "$SA_ID" '.members[]? | select(.value==$id)' <<<"$GROUP" >/dev/null; then
    pass "$SA_EMAIL is in $ADMIN_GROUP"
    info "members: $(jq -r '[.members[]?.display] | join(", ")' <<<"$GROUP")"
  else
    fail "$SA_EMAIL is not in $ADMIN_GROUP (bootstrap: no workspace or metastore admin rights)" \
      "account console → User management → Groups → $ADMIN_GROUP → Add members (DEPLOYMENT.md section 3)"
  fi
fi

section "CPU quota in $REGION (clusters use N2 machines)"
gcloud compute regions describe "$REGION" --project="$PROJECT_ID" --format=json 2>/dev/null \
  | jq -r '.quotas[] | select(.metric|test("^(CPUS|N2_CPUS)$")) | "  INFO  \(.metric): \(.usage) used of \(.limit)"'

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
else
  echo "$FAILURES check(s) failed. Fix them and re-run."
  exit 1
fi
