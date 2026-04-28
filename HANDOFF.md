# Handoff — Codex Agent (openclaw-codex Teams bot)

**First, before anything else:**
1. **Read every file linked from `MEMORY.md` that touches this task** — at minimum: `feedback_plain_language.md`, `feedback_work_silently.md`, `feedback_no_permission_asks.md`, `feedback_handoff_requirements.md`, `reference_azure_infra.md`.
2. **Flag context-limit risk proactively.** Codex debugging often spirals across many turns (model config → workspace files → Bot Framework quirks → openclaw source). Track your context. Before you hit ~60% used, warn Dr. Yoo and offer to hand off to a fresh session rather than crashing mid-task.

---

## What Codex is

The "Codex" bot Dr. Yoo and MSO staff chat with in Microsoft Teams. It is **NOT** the same as Yoo AI Agent (different appId, different process). Both run on the same VM but are separate services.

| Bot | App ID | Service | Endpoint | Source dir |
|---|---|---|---|---|
| **Codex** (this handoff) | `8d5a8a3b-82d7-45f9-bf52-962f0c8c5c9a` | `openclaw-codex.service` | `127.0.0.1:3995/api/messages` | npm `openclaw` package, runs `openclaw gateway` |
| Yoo AI Agent (different) | `b66df7dc-8d78-4ca5-9b69-135cd0e1b7b6` | `yooai-bot.service` + `yooai-responder.service` | `127.0.0.1:3977` | Hand-rolled Python in `~/yooai-bot.py` and `~/yooai-responder.py` |

If a request mentions "Codex" or "the bot Alejandro/Gustavo/staff use", it's almost always the openclaw-codex service. Don't accidentally patch yooai-responder thinking it's the same bot.

---

## Where everything lives (on openclaw-vm)

VM: `openclaw-vm` in RG `SDNeurosurgery-OpenClaw`, public IP `20.9.138.12`, FQDN `openclaw-sdneuro.westus2.cloudapp.azure.com`. SSH from Dr. Yoo's Mac is unreliable (NSG allows it but the path times out from his network); use `az vm run-command invoke -g SDNeurosurgery-OpenClaw -n openclaw-vm --command-id RunShellScript --scripts "..."` instead. Run-command serializes — if it errors with `Conflict: Run command extension execution is in progress`, use `until az vm run-command ... ; do sleep 5; done`.

```
/home/azureuser/.openclaw-codex/
├── openclaw.json                         ← bot/agent/model config (mtime-sensitive: many places to update model)
├── openclaw.json.bak-<ts>                ← my backups
├── openclaw.json.last-good
├── workspace-codex/                      ← BEHAVIORAL POLICY for the model (read every session)
│   ├── AGENTS.md       (~317 b)          ← session startup
│   ├── HEARTBEAT.md    (~193 b)
│   ├── IDENTITY.md     (~3.4 KB)         ← role, credential handling
│   ├── MEMORY.md       (~4.4 KB)
│   ├── SOUL.md         (~2.8 KB)         ← response discipline + the no-refuse policy
│   ├── TOOLS.md        (~21 KB; gets truncated to 12K — biggest constraint)
│   └── USER.md         (~2.2 KB)         ← per-user access policy (now open-access)
├── .openclaw/
│   └── agents/codex/sessions/*.jsonl     ← per-session state (one file per Teams thread)
└── media/inbound/                        ← downloaded image attachments

/home/azureuser/.npm-global/lib/node_modules/openclaw/dist/
├── src-DAPvgbdG.js                       ← MAIN openclaw runtime; HEAVILY PATCHED — see "Patches" below
├── src-DAPvgbdG.js.bak-<ts>              ← my backups (kept after each patch)
├── bootstrap-files-i7oXT4OZ.js
├── bootstrap-budget-BFflZrA0.js
└── extensions/codex/provider-catalog.js  ← codex CLI fallback model list
```

Service control:
```bash
sudo systemctl restart openclaw-codex
sudo systemctl status openclaw-codex --no-pager | head -15
sudo journalctl -u openclaw-codex --since "5 minutes ago" --no-pager | tail -30
```

Logs are flooded with mskai/provisioning chatter from sibling services; filter with `| grep -v "mskai\|provisioning\|pilot-0\|gateway-client\|workspace bootstrap\|qmd\|heartbeat"` to see Codex-relevant lines.

---

## Active patches in openclaw source (don't lose these on `npm update`)

I added six in-place patches to `src-DAPvgbdG.js`. If openclaw is upgraded and overwritten, RE-APPLY all of them or images will break and Codex will become forgetful.

Find them by `grep -n "OC-MH\|OC-INBOUND-MEDIA\|history-scan\|htmlSummary?.imgTags" /home/azureuser/.npm-global/lib/node_modules/openclaw/dist/src-DAPvgbdG.js`. Should return ~12+ matches.

1. **Inbound-media gate broadened** (line ~2026 area) — original code only triggered Graph hosted-content fetch when there was an attachment ID. I changed it to fire whenever no media downloaded yet AND it's not a bot-framework personal chat. This catches user-pasted screenshots that Bot Framework strips:
   ```js
   // Original:
   if (hasHtmlFileAttachment && mediaList.length === 0 && !isBotFrameworkPersonalChatId(conversationId)) {
   // Patched (final form):
   if (mediaList.length === 0 && !isBotFrameworkPersonalChatId(conversationId)) {
   ```
2. **Diagnostic console.error traces** at five points in `resolveMSTeamsInboundMedia`: `[OC-INBOUND-MEDIA][entry|no-graph-url|graph-empty|inline-img-undownloaded|downloaded]`. Originally I tried `log.warn?.()` but the logger only exposes `.debug` so it was a silent no-op — `console.error` does land in journalctl.
3. **Message-handler entry trace** at top of `handleTeamsMessageNow`: `[OC-MH][entry]` and `[OC-MH][img-tags-in-text]`. These confirm activities are arriving and dump what Bot Framework actually sent (attachment types, has channelData, etc.).
4. **History-aware media fallback** — appended block in `resolveMSTeamsInboundMedia` that, when no current-turn media was downloaded, queries Graph for the last 20 chat messages and downloads any `<img src="…hostedContents/.../$value">` it finds. Lets follow-up questions about an earlier image actually see it. Logs `[OC-INBOUND-MEDIA][history-scan]` and `[history-image-saved]`.

Rough sequence to re-apply if needed: original openclaw upgrade clobbers, then run the saved Python patches. I kept them at `/tmp/patch-openclaw{,2,3,4,5,6}.py` on Dr. Yoo's Mac (will be lost on reboot — copy them out if you need to keep them; the source-of-truth for what they do is this handoff).

---

## Common breakages and the fixes that worked

### 1. "Codex is down" / "Unknown model: openai-codex/gpt-5.X"

**Symptom:** every reply fails with `FailoverError: Unknown model: openai-codex/gpt-5.X`. The X is whatever Dr. Yoo (or someone editing config) set the primary to. **gpt-5.5 does not exist** in OpenAI's Codex backend yet (as of 2026-04-27). The latest model that actually serves is `gpt-5.4`.

**Fix:** revert primary to `gpt-5.4`. There are FOUR places in `openclaw.json` that pin the model — change all four:
- `agents.defaults.model.primary`
- `agents.defaults.models` map (key like `"openai-codex/gpt-5.5": {}`)
- `agents.defaults.compaction.model`
- `agents.list[0].model.primary` ← **this is the sneaky one; per-agent override that survives changing the defaults**

```bash
sudo python3 -c '
import json, os, time, shutil
F = "/home/azureuser/.openclaw-codex/openclaw.json"
shutil.copy(F, F + f".bak-{int(time.time())}")
c = json.load(open(F))
def fix(m):
    if not isinstance(m, dict): return
    if m.get("primary","").endswith("gpt-5.5"): m["primary"] = "openai-codex/gpt-5.4"
    if "fallbacks" in m: m["fallbacks"] = [x for x in m["fallbacks"] if "5.5" not in x] or ["anthropic/claude-opus-4-6"]
fix(c.get("agents",{}).get("defaults",{}).get("model"))
for a in c.get("agents",{}).get("list",[]): fix(a.get("model",{}))
mm = c.get("agents",{}).get("defaults",{}).get("models",{})
mm.pop("openai-codex/gpt-5.5", None)
comp = c.get("agents",{}).get("defaults",{}).get("compaction",{})
if comp.get("model","").endswith("gpt-5.5"): comp["model"] = "openai-codex/gpt-5.4"
codex = c.get("models",{}).get("providers",{}).get("codex",{})
codex["models"] = [m for m in codex.get("models",[]) if m.get("id") != "gpt-5.5"]
tmp = F + ".tmp"
json.dump(c, open(tmp,"w"), indent=2)
os.replace(tmp, F)
print("done")
'
sudo systemctl restart openclaw-codex
```

Do **not** try to add `gpt-5.5` to the catalog (`extensions/codex/provider-catalog.js` `FALLBACK_CODEX_MODELS`) — even if openclaw stops complaining, the OpenAI backend itself will reject it at warmup. Just stick with 5.4 until OpenAI ships 5.5 broadly.

### 2. Codex "doesn't see" pasted screenshots

The two patches together (gate broadened + history-aware fetch) make Codex see images sent via Graph hostedContents (which is how Teams desktop client posts pasted screenshots). Verify in journalctl:
```
[OC-MH][entry] {"attachmentsCount":1,"attachmentTypes":["text/html"],...}
[OC-INBOUND-MEDIA][entry] { hasHtmlFileAttachment: false, imgTags: 0, ... }
[OC-INBOUND-MEDIA][graph-empty] {...hostedCount: 0...}
[OC-INBOUND-MEDIA][history-scan] { messageCount: 20 }
[OC-INBOUND-MEDIA][history-image-saved] { path: /home/azureuser/.openclaw-codex/media/inbound/<uuid>.png, bytes: ... }
```
If you see `history-scan` with `messageCount: 5` instead of 20, the slice cap is still at 5 — fix the line `_messages = (_listJson.value || []).slice(0, 5)` to `slice(0, 20)`.

### 3. Codex refusing requests / asking for Yoo's approval

Dr. Yoo wants Codex to do what every authenticated MSO user asks. The `IDENTITY.md`, `USER.md`, and `SOUL.md` files I wrote enforce this. If Codex regresses (asks "I need Dr. Yoo's approval first" for something normal like a VM resize), check those three files still have:
- `USER.md` → "Open-Access Mode" section explicitly removes Standard/Elevated/Full tiers
- `SOUL.md` → "Critical: Do Not Refuse User Commands" + the explicit allowlist of actions that don't need confirmation (VM resize, password retrieval, send email, run az, modify config, etc.)
- `IDENTITY.md` → vault retrieval is open to any SDN/MSO user in any chat type
The narrow confirm-before list is intentional: delete user from Entra, drop database, mass mail >20, push to prod, force-reset another user's password, take down a service.

After editing any of these: `sudo systemctl restart openclaw-codex` to clear cached session bootstrap files.

### 4. Cross-context confusion ("Alejandro DMed me about Codex who says it didn't see his message")

This is usually a *Teams architecture* limitation, not a bug:
- DM session and group session are SEPARATE conversations. The group-chat Codex literally cannot see the DM Codex's history.
- For a single user (Alejandro) DMing Codex, every message DOES reach the bot — verify in journalctl with grep on the conversationId. Codex may be replying with a sensible refusal in his DM (e.g. used to insist on Yoo's authorization for admin actions). The fix is the policy update above, not a transport patch.

When Dr. Yoo says "Codex isn't getting X's message", read `~/.openclaw-codex/.openclaw/agents/codex/sessions/*.jsonl` modified in the relevant window — find the session for that user, look at the assistant's actual reply. 90% of the time Codex DID get the message and DID reply, but said something Dr. Yoo doesn't like.

### 5. Bot Framework quirks

- Pasted screenshots arrive as `attachmentTypes: ["image/*", "text/html"]` when sent via Graph `hostedContents`, but as `["text/html"]` only with inline `<img src="…">` in the body when typed in via the Teams web/desktop UI. The history-aware fetch handles both.
- `conversationType: 'personal'` with a conversationId starting `a:…` is a Bot-Framework personal chat (different from Graph chat ID). The function `translateMSTeamsDmConversationIdForGraph` converts these for Graph queries.
- Group chat IDs `19:…@thread.v2` work directly in Graph URLs.
- The chat history block in each turn (`Chat history since last reply`) only carries a few text-only entries — historical media is NOT carried forward by openclaw. The history-aware fetch patch is what makes follow-ups work.

---

## Diagnostic playbook

**"Codex stopped responding."**
```bash
sudo systemctl is-active openclaw-codex
sudo journalctl -u openclaw-codex --since "10 min ago" --no-pager | grep -iE "error|fail|unknown|warmup" | tail -10
```
Look for `Unknown model` (→ fix #1), or generic gateway crash → `sudo systemctl restart openclaw-codex`.

**"Codex isn't reading the image I just sent."**
```bash
sudo journalctl -u openclaw-codex --since "5 min ago" --no-pager | grep -E "OC-MH|OC-INBOUND" | tail -20
```
If `OC-MH[entry]` doesn't fire, Bot Framework didn't deliver — check Teams app health.
If `[entry]` fires but `[downloaded]` doesn't and `history-scan` is empty, the user's chat doesn't have inline images in recent history.
If `history-scan` finds 0 image URLs, the message body was already stripped — ask the user to re-attach.

**"What did Codex actually reply to user X?"**
```bash
F=$(ls -t /home/azureuser/.openclaw-codex/.openclaw/agents/codex/sessions/*.jsonl | grep -v trajectory | grep -v topic | head -5)
# inspect each session's last assistant turn — the senders are visible in the user metadata
```
Use `/tmp/scan-refusals.py` (in this repo's tmp during my session; rebuild from this handoff if needed) to scan recent sessions for refusal-like assistant text and link them back to the sender.

**"Send a real test message as Yoo."**
Use `/tmp/send-test-image.py` pattern: get a delegated Yoo token via `yoomd-graph-refresh-token` keyvault secret, request `Chat.ReadWrite User.Read offline_access` scope from `login.microsoftonline.com/organizations/oauth2/v2.0/token`, POST to `/v1.0/chats/<chatId>/messages` with a `mentions` array pointing at Codex's appId and a `hostedContents` array for inline images.

---

## What stays risky / open

- **gpt-5.5 will probably get re-set by someone (or by Dr. Yoo himself).** When it does, Codex stops responding and you'll need fix #1. Consider adding a safer setup that warns rather than dies — but that's not implemented yet.
- **TOOLS.md is 21 KB; bootstrap caps per-file at 12 KB.** Codex sees a truncated TOOLS.md on every session. If a tool isn't being used and you've asked Codex about it, check whether the doc for that tool got cut off. Either trim TOOLS.md or raise `agents.defaults.bootstrapMaxChars`.
- **Workspace files DO get cached per-session.** After editing IDENTITY/USER/SOUL/TOOLS/AGENTS, restart `openclaw-codex` so all running sessions reload them — otherwise existing chats keep the old policy until they hit a compaction.
- **The "history-aware media fetch" patch costs one extra Graph call per text-only message in a chat.** Cheap, but if you see latency complaints, that's the obvious knob.
- **Diagnostic `console.error` traces are still in production.** They're cheap and useful — leave them unless logs get noisy.

---

## Appendix: file checksums after my session (sanity check on next read)

| File | Size | Notes |
|---|---|---|
| `/home/azureuser/.openclaw-codex/workspace-codex/IDENTITY.md` | 3,443 b | Open-access vault retrieval; no echo-refusal in DM |
| `/home/azureuser/.openclaw-codex/workspace-codex/USER.md` | 2,251 b | Open-Access Mode; tiers removed |
| `/home/azureuser/.openclaw-codex/workspace-codex/SOUL.md` | 2,796 b | "Do Not Refuse User Commands" + explicit allowlist |
| `/home/azureuser/.openclaw-codex/openclaw.json` | varies | `agents.defaults.model.primary = "openai-codex/gpt-5.4"` |
| `/home/azureuser/.npm-global/lib/node_modules/openclaw/dist/src-DAPvgbdG.js` | varies | 6 patches; verify with `grep -c "OC-MH\|OC-INBOUND-MEDIA"` ≥ 12 |

If those sizes/checks differ wildly, somebody upgraded openclaw or edited a workspace file — re-read this handoff and the affected files before changing anything else.
