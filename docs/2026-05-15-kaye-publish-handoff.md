# Kaye's bot — Teams catalog publish handoff (2026-05-15)

## Status right now

Kaye's bot on the VM is alive and working. She cannot add it to her Teams chats because the Teams app catalog entry doesn't exist. We tried to publish today and Microsoft silently rejected the upload — the publishing account is in a cooldown.

**Do nothing until 2026-05-16, late morning at the earliest.** Retrying before that will deepen the cooldown.

## What's already done (don't redo)

- Bot resource `OpenClaw-KayeAgent` exists in Azure with msaAppId `07af914d-780c-45ac-9b88-3f069bc0a020`. Endpoint: `https://openclaw-sdneuro.westus2.cloudapp.azure.com/kayeai/api/messages`.
- VM services `kaye-bot.service` and `kaye-responder.service` are running.
- Manifest zip at `/home/azureuser/kaye-teams-app.zip` (3,310 bytes, dated 2026-04-30) is correct — inspected today. Contains:
  - `manifest.json` with `id` (externalId) **`515f7dd8-cede-4e89-8012-a861e0a71f3d`** — keep this forever, never change
  - `bots[0].botId` = `07af914d-780c-45ac-9b88-3f069bc0a020` (matches Azure msaAppId — verified)
  - `packageName` = `com.sdneurosurgery.kayeaiagent`
  - `name.short` = "Kaye AI" / `name.full` = "Kaye's AI Agent"
  - `version` = `1.0.0`
  - `color.png`, `outline.png`
- Today's upload attempt produced orphan `teamsApp.id` = **`c28c52ce-eabe-4db5-a980-01462832d565`**. It returned 201 from POST but every GET on that id is 404. It's stuck. Do not reference, install, or delete this id.

## What was confirmed today (so tomorrow's session doesn't re-investigate)

| Question | Answer (confirmed 2026-05-15) |
|---|---|
| Does Microsoft have any catalog entry for Kaye by externalId? | No (matches: 0) |
| By displayName "Kaye's AI Agent"? | No |
| By displayName "Kaye Elamparo"? | No |
| By displayName "Kaye AI"? | No |
| Does the orphan id from today's upload resolve? | No (404, both bare GET and with `$expand=appDefinitions`) |
| Is the manifest zip valid and Kaye-specific? | Yes — botId matches the Azure resource, no Aixa copy-paste artifacts |
| Did AppPublisher token mint succeed? | Yes (2987 chars) |
| Did YooMD chat token mint succeed? | Yes (3559 chars) |

So: cooldown is the only remaining explanation.

## Retry plan for 2026-05-16

**Wait until at least mid-morning PDT 2026-05-16** (≥24h since the failed POST at ~2026-05-15 ~01:55 UTC). Don't poke the catalog before then.

When ready:

1. Re-run the safe check first — same four read-only queries as today (`docs/teams-app-publishing.md` rule 3 verify pattern). Confirm all still return 0. If anything shows up, **switch to `appDefinitions` versioning path on that existing id, do NOT upload fresh**.
2. If still all 0, **single fresh upload** of the existing `/home/azureuser/kaye-teams-app.zip`. Do not change the manifest's `id` (externalId). Do not change anything in the zip.
3. POST to `/v1.0/appCatalogs/teamsApps` with the AppPublisher token. Capture the new `teamsApp.id`.
4. Poll GET on that new id up to 5 min, every 10 s. If still 404 after 5 min, **STOP**. The cooldown has extended past 24h — write another handoff, escalate. Don't retry.
5. If 200, mint YooMD chat token, POST to `/v1.0/users/53ef6cdf-3955-4ba5-a361-cef88ea6071a/teamwork/installedApps` with the new id.
6. Verify by GET on Kaye's `installedApps` — expect to see the new teamsApp.id in the list.
7. Save the new teamsApp.id in this file under "permanent record" below for future version bumps.

The full dispatch is in `.requests/az-run-command/kaye-publish-stage2.json` from today's branch — can be copied and run again with a fresh filename.

## Update — second attempt confirmed the cooldown is real

After writing the original handoff, ran a second upload (user-authorized). Result: `409 Conflict` with body:

> `App with same id already exists in the tenant. UserId: 'e0d48eb4-1eb3-4263-a72e-f6ad4ef32238', AppId: 'c5d5dbb3-f135-4cc2-8a59-3b4dfba95600', ExternalId: '515f7dd8-cede-4e89-8012-a861e0a71f3d', entitlementId: c28c52ce-eabe-4db5-a980-01462832d565, state: Installed`

Initially looked like a rescue (we got a "real" teamsApp.id from the error). But: `GET /v1.0/appCatalogs/teamsApps/c5d5dbb3-...` with the AppPublisher token returned **404**, same as the original `c28c52ce-...` orphan. Microsoft remembers enough to block fresh uploads (409) but won't actually surface the entry (404). That's the cooldown signature, just sideways.

**Both ids `c28c52ce-...` and `c5d5dbb3-...` are dead.** Do not try to GET, install against, or delete either of them. They will become live (or remain dead and decay) once the cooldown lifts.

## Permanent record (fill in after success)

- Kaye's published `teamsApp.id`: _(fill in once publish succeeds — NOT `c28c52ce` or `c5d5dbb3`; both are quarantined artifacts)_
- Kaye's externalId (won't change): `515f7dd8-cede-4e89-8012-a861e0a71f3d`
- Future version updates: `POST /v1.0/appCatalogs/teamsApps/{teamsAppId}/appDefinitions` — never delete-and-reupload (per `docs/teams-app-publishing.md` Rule 1)

## Identifiers used today (for token mints)

- AppPublisher refresh token: `SDN-YooVault/yoomd-graph-refresh-token-appcatalog` (client_id `9f4cd925-fcc7-4f42-8dc2-ae98bcad28a6`, scope `AppCatalog.ReadWrite.All offline_access`)
- YooMD chat refresh token: `SDN-YooVault/yoomd-graph-refresh-token` (client_id `14d82eec-204b-4c2f-b7e8-296a70dab67e`, scope `https://graph.microsoft.com/.default offline_access`)
- Kaye Elamparo's AAD object id: `53ef6cdf-3955-4ba5-a361-cef88ea6071a`

## If anyone messages Dr. Yoo or Kaye in the interim

Plain-English answer to give: "Kaye's bot is built and ready. We're stuck on a 24-hour Microsoft-side cooldown that's blocking the final step of putting it in Teams' app picker. Will be done tomorrow."

## Pointer for tomorrow's first action

Read this file first. Then re-run the four safe queries from `.requests/az-run-command/kaye-safe-check-v2.json` (substitute a fresh filename). Only after all four return 0 again, proceed to the publish dispatch.
