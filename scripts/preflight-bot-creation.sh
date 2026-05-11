#!/usr/bin/env bash
# preflight-bot-creation.sh — run before building any new bot. Catches the
# tenant policy gate, the AppPublisher refresh-token expiry, and the VM
# health issues that wasted hours on 2026-05-11.
#
# Usage: bash preflight-bot-creation.sh [reference-bot-shortname]
#
# Exit 0 = safe to build a new bot. Exit 1 = STOP, fix the failure, do not
# proceed.

set -uo pipefail
REFERENCE_BOT="${1:-cameron}"   # an existing healthy bot used as canary
TENANT=50186224-2255-444a-b321-60a84114115c
TEAMS_GRAPH_CLI=14d82eec-204b-4c2f-b7e8-296a70dab67e
APP_PUBLISHER=9f4cd925-fcc7-4f42-8dc2-ae98bcad28a6
YOO_AAD=e0d48eb4-1eb3-4263-a72e-f6ad4ef32238   # Dr. Yoo's user id (test target)

PASS=true
fail() { echo "  ✗ $*"; PASS=false; }
ok()   { echo "  ✓ $*"; }

echo "=== Phase 0.1: AppPublisher refresh token mints cleanly ==="
RT_APPCAT=$(az keyvault secret show --vault-name SDN-YooVault --name yoomd-graph-refresh-token-appcatalog --query value -o tsv 2>/dev/null)
if [ -z "$RT_APPCAT" ]; then
  fail "appcatalog refresh token missing from vault"
else
  RESP=$(curl -sS -X POST "https://login.microsoftonline.com/organizations/oauth2/v2.0/token" \
    --data-urlencode "client_id=$APP_PUBLISHER" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$RT_APPCAT" \
    --data-urlencode "scope=AppCatalog.ReadWrite.All offline_access")
  APPCAT_AT=$(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
  if [ -n "$APPCAT_AT" ]; then
    ok "AppPublisher token minted ($APP_PUBLISHER) with AppCatalog.ReadWrite.All"
  else
    fail "AppPublisher token mint FAILED: $(echo "$RESP" | head -c 200)"
  fi
fi

echo
echo "=== Phase 0.2: YooMD chat refresh token mints with install scope ==="
RT_CHAT=$(az keyvault secret show --vault-name SDN-YooVault --name yoomd-graph-refresh-token --query value -o tsv 2>/dev/null)
if [ -z "$RT_CHAT" ]; then
  fail "yoomd refresh token missing from vault"
else
  RESP=$(curl -sS -X POST "https://login.microsoftonline.com/organizations/oauth2/v2.0/token" \
    --data-urlencode "client_id=$TEAMS_GRAPH_CLI" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "refresh_token=$RT_CHAT" \
    --data-urlencode "scope=TeamsAppInstallation.ReadWriteForUser.All offline_access")
  CHAT_AT=$(echo "$RESP" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
  if [ -n "$CHAT_AT" ]; then
    ok "YooMD chat token minted with install scope"
  else
    fail "YooMD chat token mint FAILED: $(echo "$RESP" | head -c 200)"
  fi
fi

echo
echo "=== Phase 0.3: Tenant Teams app permission policy is open (canary install probe) ==="
# Find a working bot's catalog app id to use as canary
CANARY_APP=$(curl -sS -G -H "Authorization: Bearer $APPCAT_AT" \
  "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps" \
  --data-urlencode "\$filter=displayName eq 'Cameron Claude'" \
  | python3 -c "import json,sys;v=json.load(sys.stdin).get('value',[]);print(v[0]['id'] if v else '')" 2>/dev/null)

if [ -z "$CANARY_APP" ]; then
  fail "no canary 'Cameron Claude' app in catalog — can't test policy gate"
else
  # Dry-run install for Dr. Yoo (he probably already has it; 409 Conflict is also OK)
  CODE=$(curl -sS -o /tmp/preflight-r.json -w '%{http_code}' -X POST \
    "https://graph.microsoft.com/v1.0/users/$YOO_AAD/teamwork/installedApps" \
    -H "Authorization: Bearer $CHAT_AT" \
    -H "Content-Type: application/json" \
    -d "{\"teamsApp@odata.bind\":\"https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$CANARY_APP\"}")
  case "$CODE" in
    201|200)
      ok "canary install succeeded ($CODE) — policy gate OPEN"
      ;;
    409)
      if grep -q 'Conflict\|already' /tmp/preflight-r.json 2>/dev/null; then
        ok "canary already installed for Dr. Yoo ($CODE) — policy gate OPEN"
      else
        fail "409 with unexpected body: $(cat /tmp/preflight-r.json | head -c 200)"
      fi
      ;;
    403)
      if grep -q 'blocked by app permission policy' /tmp/preflight-r.json 2>/dev/null; then
        fail "POLICY GATE CLOSED — tenant blocking 'Private' apps. Do not build new bots until fixed (Teams Admin Center → Manage apps → Permission policies → Custom apps → Allow)."
      else
        fail "unexpected 403: $(cat /tmp/preflight-r.json | head -c 200)"
      fi
      ;;
    *)
      fail "unexpected HTTP $CODE on canary install: $(cat /tmp/preflight-r.json | head -c 200)"
      ;;
  esac
  rm -f /tmp/preflight-r.json
fi

echo
echo "=== Phase 0.4: Reference bot $REFERENCE_BOT is healthy on VM ==="
echo "(skip — run this externally via dispatch-az-run-command since this script may run from anywhere)"
echo "Recommended check:"
echo "  bash /home/azureuser/bot-health-check.sh $REFERENCE_BOT"
echo "  → must return healthy: true"

echo
if [ "$PASS" = "true" ]; then
  echo "==> PREFLIGHT PASSED. Safe to build a new bot."
  exit 0
else
  echo "==> PREFLIGHT FAILED. Do not proceed. Fix the failures above first."
  exit 1
fi
