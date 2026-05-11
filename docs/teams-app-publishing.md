# Publishing Teams apps for user-personal bots — the rules learned the hard way

When provisioning a new personal Claude bot for a user, you need to publish a custom Teams app to the org catalog and install it for that user. The Graph API for this is friendly-looking but has **two failure modes that look identical** but require completely different responses. This playbook encodes the rules learned from the 2026-05-11 incident where every Teams app uploaded by MSO Claude was silently quarantined by Microsoft after a few delete-and-reupload cycles.

## RULE 0: Use the dedicated AppPublisher identity, NOT the chat YooMD token

The `yoomd-graph-refresh-token` secret in `SDN-YooVault` is the **general-purpose** YooMD delegated token (Microsoft Graph Command Line Tools client, `14d82eec-...`). It's used for chat/files/mail/calendar/sites operations. **Do NOT use it for `appCatalogs/teamsApps` uploads** — there's a separate identity built specifically for that, and using the wrong one is what triggers the per-identity anti-abuse cooldown.

The right identity for catalog publishes:

| Field | Value |
|---|---|
| Vault secret | `SDN-YooVault/yoomd-graph-refresh-token-appcatalog` |
| Client ID (OAuth `client_id`) | `9f4cd925-fcc7-4f42-8dc2-ae98bcad28a6` |
| App display name | `OpenClaw-AppPublisher` |
| Scopes | `AppCatalog.ReadWrite.All` |
| Token endpoint | `https://login.microsoftonline.com/organizations/oauth2/v2.0/token` |

Mint pattern:

```bash
RT=$(az keyvault secret show --vault-name SDN-YooVault --name yoomd-graph-refresh-token-appcatalog --query value -o tsv)
AT=$(curl -sS -X POST "https://login.microsoftonline.com/organizations/oauth2/v2.0/token" \
  --data-urlencode "client_id=9f4cd925-fcc7-4f42-8dc2-ae98bcad28a6" \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "refresh_token=$RT" \
  --data-urlencode "scope=AppCatalog.ReadWrite.All offline_access" \
  | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))")
```

Use `$AT` as the Authorization bearer for all `POST /v1.0/appCatalogs/teamsApps` and `POST .../appDefinitions` calls.

For per-user **installs** (different operation), use the YooMD chat token (`yoomd-graph-refresh-token`, client `14d82eec-...`) with the install scope — that one's fine for installs, just not for uploads. The two operations use different identities.

## The five rules

### Rule 1: One upload, one app, forever

Every fresh `POST /v1.0/appCatalogs/teamsApps` generates a new `teamsApp.id` (a GUID). Microsoft tracks these. **If you upload-delete-reupload the same logical app more than 2-3 times in an hour, Microsoft's anti-abuse logic kicks in and silently quarantines every subsequent upload.** The new app gets a 201 response with an ID, but `GET /appCatalogs/teamsApps/{id}` returns 404 and `displayName` searches return count=0. The app appears to exist (the install endpoint still references it) but isn't actually published.

**The fix is not to wait it out** — the cooldown is approximately 24h, sometimes longer. The fix is to never trigger it.

When you need to update an existing Teams app, use the **`appDefinitions` versioning path**, not delete-and-reupload:

```
POST /v1.0/appCatalogs/teamsApps/{existingAppId}/appDefinitions
```

Body: a fresh manifest zip as multipart/form-data. The new definition slots in under the existing app's history; the `teamsApp.id` (the public GUID) stays the same; users who already installed the app get the new version on their next session.

### Rule 2: Verify-before-retry

If `POST /users/{id}/teamwork/installedApps` returns 403, **DO NOT retry the install**. Your first command is:

```bash
GET /v1.0/appCatalogs/teamsApps/{teamsAppId}
```

If the response is **404 NotFound**, the app is gone. Retrying install is pointless. You're past the cooldown trigger. Stop, escalate.

If the response is **200 with the app**, then it really is a policy issue. *Then* you escalate to admin UI (see `reference_teams_app_install_admin_ui.md` in user memory).

### Rule 3: Verify success after upload

`POST /v1.0/appCatalogs/teamsApps` returning 201 does NOT mean the app is published. Microsoft accepts the bytes, returns an ID, and then asynchronously decides whether to publish. The truth is:

```bash
GET /v1.0/appCatalogs/teamsApps?$filter=displayName eq '<your app name>'
```

If `value[]` contains your app within 60 seconds of upload, it's published. If it doesn't show up after 5 minutes, **the upload was silently rejected**. Do not retry — you'll deepen the cooldown. Stop and escalate.

### Rule 4: 403 "blocked by app permission policy" is ambiguous

The error body looks like:

```json
{ "error": { "code": "Forbidden",
  "message": "App is blocked by app permission policy. TenantId: ..., UserObjectId: ..., AppId: ..., AppType: Private" } }
```

This message fires in TWO different situations:

1. **Real policy block** — the tenant's Teams App Permission Policy genuinely blocks `Private` apps for this user. Fix: drive Teams Admin Center UI (admin-route bypasses user-policy gate).
2. **Stale-cache red herring** — the app was deleted from the catalog after a delete-and-reupload, but the install endpoint's backstore still has a reference. The user-policy check passes against the stale `AppType: Private` and returns 403. **The real failure is upstream: the app isn't published anymore.**

Always run Rule 2's check first to distinguish. Skipping that check and assuming it's a policy block was the entire 2026-05-11 dead end.

### Rule 5: Stop signal

If you have done **more than two** upload-delete cycles on the same logical app in the past hour, **STOP**. You have probably triggered Microsoft's anti-abuse logic. Continuing makes it worse. Write a handoff documenting state and escalate to Dr. Yoo. Don't try to "fix" it by uploading harder.

## The canonical publish + install sequence

For a new bot named `<NAME>` Claude that targets user `<USER_AAD_ID>`:

```bash
# 1. Build the manifest zip with a fresh externalId UUID. Save the zip locally.
#    Do NOT change this externalId on subsequent versions — keep it forever.

# 2. Upload once. Capture the response.
RESP=$(curl -sS -X POST \
  "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps" \
  -H "Authorization: Bearer $YOOMD_TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @manifest.zip)
APP_ID=$(echo "$RESP" | jq -r .id)
echo "uploaded as app id: $APP_ID"

# 3. Verify it published — poll up to 5 minutes.
for i in $(seq 1 30); do
  STATUS=$(curl -sS -o /tmp/r -w '%{http_code}' \
    "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$APP_ID" \
    -H "Authorization: Bearer $YOOMD_TOKEN")
  [ "$STATUS" = "200" ] && { echo "published"; break; }
  sleep 10
done
[ "$STATUS" = "200" ] || { echo "FAIL: did not publish within 5min, ESCALATE — DO NOT RETRY"; exit 1; }

# 4. Install for the user. Verify-before-claim-success.
curl -sS -X POST \
  "https://graph.microsoft.com/v1.0/users/$USER_AAD_ID/teamwork/installedApps" \
  -H "Authorization: Bearer $YOOMD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"teamsApp@odata.bind\":\"https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$APP_ID\"}"

# 5. Verify the install record actually exists and points at a live app.
curl -sS -G \
  "https://graph.microsoft.com/v1.0/users/$USER_AAD_ID/teamwork/installedApps" \
  --data-urlencode "\$expand=teamsApp" \
  -H "Authorization: Bearer $YOOMD_TOKEN" \
  | jq ".value[] | select(.teamsApp.id == \"$APP_ID\") | .teamsApp.displayName"
# Expect: prints the bot name. If empty, the install didn't take.
```

## Version updates — the right way

```bash
# Bump version in manifest.json, repack the zip, do NOT change externalId.
# Then:
curl -sS -X POST \
  "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$EXISTING_APP_ID/appDefinitions" \
  -H "Authorization: Bearer $YOOMD_TOKEN" \
  -H "Content-Type: application/zip" \
  --data-binary @manifest-v2.zip

# The teamsApp.id stays the same. Users who have it installed get the new
# version automatically on next session. No re-install needed.
```

**Never delete a published app to upload a "new version".** That's the trap that breaks everything.

## Anti-patterns to avoid

| What you did | What you should do |
|---|---|
| Got 403 on install → retried install | Check `GET /teamsApps/{id}` first. 404 = upload failed, not a policy issue |
| Got "blocked by policy" → uploaded again with fresh GUID | Stop. Verify the existing app's state. Escalate before re-uploading |
| Couldn't see app in catalog list → re-uploaded | Wait full 5 minutes with periodic polling. Re-upload only after confirmed absence and only ONCE |
| Wanted to fix a manifest bug → deleted and re-uploaded | Use `POST .../appDefinitions` to add a new version to the same app |
| Saw `count=0` for displayName → assumed something failed and retried | If `count=0` matches a non-zero attempt earlier, you've already hit cooldown. Do not retry. |

## When you've already triggered the cooldown

Symptoms:
- `POST /v1.0/appCatalogs/teamsApps` returns 201 with an ID
- `GET /v1.0/appCatalogs/teamsApps/{id}` returns 404
- `GET ?$filter=displayName eq '<name>'` returns count=0
- Install fails with 403 "blocked by app permission policy"

Wait ≥24h before any further Teams catalog operations on this tenant. Don't keep poking. Write a handoff documenting the bots that couldn't be deployed; tell Dr. Yoo. Resume after cooldown.

## Diagnostic order when a Teams install fails

```
1. GET /v1.0/appCatalogs/teamsApps/{appId}         → 200? Continue. 404? App is gone, STOP.
2. GET ?$filter=displayName eq '<name>'             → count=1? Right app. count=0 or >1? Wrong assumptions.
3. GET /users/{aadId}/teamwork/installedApps        → already installed against THIS id? Maybe the bot is fine, the issue is elsewhere
4. Then and only then consider tenant policy / admin UI
```

Don't skip steps. The 2026-05-11 chain of failures all came from skipping step 1 and assuming step 4.
