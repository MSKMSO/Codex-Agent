# Runbook — rotate a bot's client secret

When the diagnostic in `docs/multi-bot-debugging.md` step 2 returns `AADSTS7000215: Invalid client secret provided`, the bot's `creds.json` contains the secret ID instead of the secret value. This runbook fixes it without ever sending the secret value back through the chat / response file.

## One-shot script

Dispatch via `.requests/az-run-command/<your-id>.json`:

```json
{
  "vm": "openclaw-vm",
  "script": "BOT_NAME=emily-claude APP_ID=b1d02264-28fe-49f1-ae71-b50b6809f852 bash -c '\nset -e\nsudo -u azureuser bash -lc \"az login --identity >/dev/null 2>&1\"\nAPP_OBJ=$(sudo -u azureuser az rest --method GET --url \"https://graph.microsoft.com/v1.0/applications?\\$filter=appId eq '\\''$APP_ID'\\''&\\$select=id\" --query \"value[0].id\" -o tsv)\nEND=$(date -u -d \"+90 days\" \"+%Y-%m-%dT%H:%M:%SZ\")\nRESP=$(sudo -u azureuser az rest --method POST --url \"https://graph.microsoft.com/v1.0/applications/$APP_OBJ/addPassword\" --headers \"Content-Type=application/json\" --body \"{\\\"passwordCredential\\\":{\\\"displayName\\\":\\\"rotated-$(date -u +%Y%m%d)\\\",\\\"endDateTime\\\":\\\"$END\\\"}}\")\nSECRET=$(echo \"$RESP\" | python3 -c \"import json,sys;print(json.load(sys.stdin).get(\\\"secretText\\\",\\\"\\\"))\")\n[ -n \"$SECRET\" ] || { echo FAIL: no secretText; exit 1; }\nCREDS=/home/azureuser/.${BOT_NAME}-bot/creds.json\nsudo cp \"$CREDS\" \"$CREDS.bak-$(date -u +%s)\"\nsudo -u azureuser python3 -c \"\\nimport json\\nd = json.load(open(\\\"$CREDS\\\"))\\nd[\\\"client_secret\\\"] = \\\"\\\"\\\"$SECRET\\\"\\\"\\\"\\nopen(\\\"$CREDS\\\",\\\"w\\\").write(json.dumps(d, indent=2))\\n\"\nunset SECRET\nsudo systemctl restart ${BOT_NAME}-bot.service ${BOT_NAME}-responder.service\nsleep 30\necho OK: $BOT_NAME secret rotated; restart confirmed; AAD propagation wait done\n'"
}
```

The escaping above is unpleasant because of the JSON-in-shell layers. Easier: keep the script body as a heredoc on the VM at `/home/azureuser/rotate-bot-secret.sh` and just call it with two args.

## Cleaner: VM-side helper

Have a maintained helper script on the VM. Dispatch shrinks to:

```json
{"vm":"openclaw-vm","script":"bash /home/azureuser/rotate-bot-secret.sh emily-claude b1d02264-28fe-49f1-ae71-b50b6809f852"}
```

The helper itself is in this repo at `scripts/vm/rotate-bot-secret.sh` and gets deployed to the VM via the `deploy-vm-script` workflow when this repo updates it. (Helper not yet present — first invocation of this runbook deploys it; see issue tracker.)

## Critical rules

1. **Never echo `$SECRET` to stdout.** It would land in `.responses/az-run-command/*.json` in this repo.
2. **Wait 30 seconds** before testing — AAD has propagation delay between `addPassword` and the secret being usable for token requests. Testing immediately gives a misleading 401 even when the rotation succeeded.
3. **Don't delete the old password.** `addPassword` is additive — leave the old one as fallback for a week, then prune.
4. **Restart both `{name}-bot.service` and `{name}-responder.service`** — they read creds independently.

## Verifying the rotation worked

```bash
APP_ID=$(jq -r .app_id /home/azureuser/.{name}-bot/creds.json)
SEC=$(jq -r .client_secret /home/azureuser/.{name}-bot/creds.json)
TEN=$(jq -r .tenant /home/azureuser/.{name}-bot/creds.json)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$APP_ID" \
  --data-urlencode "client_secret=$SEC" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://api.botframework.com/.default"
unset SEC
# expect: 200
```
