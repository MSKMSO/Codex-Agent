# Debugging multiple bots built from the same template

When several bots are built from the same template and one works while others don't, the actual bug is **almost always** in the per-bot drift (creds, secrets, copy-paste errors in the responder), not in the URL config, network, or Microsoft side. This playbook encodes the order to check things, learned the hard way over multiple multi-hour sessions.

## Hard rule: diff before you guess

> **If N bots run from the same template and bot A works but bot B doesn't, your first command is `diff` between A's responder/bot/creds files and B's.**
>
> Not `az bot show`, not `journalctl`, not `curl` — `diff`. Five seconds. It would have caught the duplicate `_post_reply_orig_protect` recursion bug on 2026-05-07 in one round-trip instead of eight.

```bash
# From a dispatch-az-run-command request:
{"vm":"openclaw-vm","script":"diff /home/azureuser/aixa-responder.py /home/azureuser/emily-claude-responder.py | head -100"}
```

Apply this to every file the bots share by template:

- `~/{name}-bot.py` (or `{name}-claude-bot.py`)
- `~/{name}-responder.py`
- `~/{name}-graph-token.sh`
- `~/{name}-send-to.sh`
- `~/.{name}-bot/creds.json` — only diff the SHAPE (`jq 'keys'`), never the values

## Diagnostic order when a bot is silent in Teams

Run these top-to-bottom. Stop at the first one that fails. Don't skip ahead.

### 1. Are the services running?

```bash
systemctl is-active {name}-bot.service {name}-responder.service
# expect: active active
```

If either is failed, `journalctl -u {name}-bot -n 50 --no-pager`. Most common failure: port collision (another service grabbed the port).

### 2. Can the bot's SP authenticate to Bot Framework?

This is the **single most common failure mode** for new bots. Symptom: Microsoft → bot delivery fails, you see HTTP 401 in nginx logs, no inbound activity in `~/.{name}-bot/activities.jsonl`.

```bash
APP_ID=$(jq -r .app_id  /home/azureuser/.{name}-bot/creds.json)
SEC=$(  jq -r .client_secret /home/azureuser/.{name}-bot/creds.json)
TEN=$(  jq -r .tenant   /home/azureuser/.{name}-bot/creds.json)
curl -sS -X POST "https://login.microsoftonline.com/$TEN/oauth2/v2.0/token" \
  --data-urlencode "client_id=$APP_ID" \
  --data-urlencode "client_secret=$SEC" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "scope=https://api.botframework.com/.default" \
  | jq '. | {ok: (has("access_token")), err: .error, msg: .error_description[:120]}'
```

- **`AADSTS7000215: Invalid client secret provided`** → `creds.json` has the secret **ID** instead of the secret **value**. This happens when the bot was provisioned and the wrong field of the `addPassword` response was captured. **Fix: rotate the secret** (see `runbook-rotate-bot-secret.md`).
- **`AADSTS700016: Application not found`** → the SP was deleted or never created in this tenant. Re-provision via `az ad app create` + `az ad sp create`.
- **`unauthorized_client`** → audience/scope mismatch. Make sure scope is `https://api.botframework.com/.default`, not Microsoft Graph.

### 3. Does Microsoft's saved endpoint match the running service?

```bash
# Microsoft's view:
az bot show -g SDNeurosurgery-OpenClaw -n OpenClaw-{Name}Claude --query properties.endpoint -o tsv
# Local nginx route:
sudo grep -r "{name}/api/messages" /etc/nginx/sites-enabled/ | head -3
# Service port:
sudo ss -tlnp | grep $(systemctl show {name}-bot -p MainPID --value)
```

These three should chain: Azure endpoint → nginx server_name + location → localhost port → service. **In practice this is almost never the broken link** for templated bots — the URLs were generated correctly at provisioning time. Don't waste a turn here unless step 2 passed.

### 4. Is the responder code identical to a working bot's?

```bash
diff /home/azureuser/{working-bot}-responder.py /home/azureuser/{broken-bot}-responder.py
```

Look for:
- Duplicate function/class definitions (recursion if both wrap the same target)
- Off-by-one differences in template variable substitution (wrong app_id, wrong chat_id baked in)
- Missing imports

### 5. Is the Teams channel actually enabled?

```bash
az bot msteams show -g SDNeurosurgery-OpenClaw -n OpenClaw-{Name}Claude --query "{enabled:properties.isEnabled}"
```

Off-by-default on freshly created Bot Service resources. `az bot msteams create` to enable.

### 6. Is the bot installed in the chat?

If steps 1–5 all pass and the bot is silent in ONE specific chat (but works elsewhere), the bot wasn't installed in that chat. Use `{name}-send-to.sh` with the chat id; it auto-installs on first use (and shows a system "joined the chat" notification — that's normal).

## Anti-patterns to avoid

- **Assuming the URL is wrong without verifying.** The 2026-05-07 dance started here. URL config in templated bots is set at provisioning and almost never drifts.
- **Restarting services without diagnosing.** Restart fixes ~5% of bot issues. Diagnose first.
- **Going down a single bug deep when the symptom suggests multiple.** "Aixa works, three others don't" → drift between the three, not a Microsoft outage.
- **Storing the secret ID in `creds.json`.** When you `addPassword`, the response is `{"keyId": "...", "secretText": "..."}`. **Save `secretText`, never `keyId`.**

## Reusable runbooks in this repo

- `docs/runbook-rotate-bot-secret.md` — when step 2 fails with `AADSTS7000215`
- `docs/dispatch-az-run-command.md` — how to run any of these diagnostics from your sandbox
- `docs/dispatch-gh-proxy.md` (in Virtual-Machines) — same pattern for GitHub API calls
