# Bot returns "Had trouble generating a reply" — what's actually wrong

When a user reports a bot in Teams replying with `⚠️ Had trouble generating a reply — please retry in a moment.`, the failure could be ANY of these — they all surface as that same message:

1. **Anthropic rate limit on the org token** (transient)
2. **Auto-injected code broke the function** that calls Claude CLI (persistent, the kind of thing you have to fix in source)
3. Bot service down / crash-looping (rare; obvious from `systemctl is-active`)
4. Graph chat metadata 404 (red herring — see below)

Don't guess. Run the diagnostic in order. The wrong intervention (copying tokens between bots, restarting things, dispatching more retries) makes #2 worse, not better.

## Symptoms to capture first

For the failing bot (call it `<bot>`):

```bash
# 1. Service status
systemctl is-active <bot>-bot.service <bot>-responder.service
# Expected: active active. If anything else, that's your problem.

# 2. Activities log mtime vs. outbound log mtime
ls -la /home/azureuser/.<bot>-bot/activities.jsonl   /home/azureuser/.<bot>-bot/outbound.jsonl
# Activities updates → bot.py IS receiving messages.
# Outbound only has "Had trouble" replies → responder IS running but Claude call is failing.

# 3. Most recent responder error pattern
sudo tail -10 /home/azureuser/.<bot>-bot/responder-errors.log

# 4. Most recent responder DEBUG log mtime + entries
sudo ls -la /home/azureuser/.<bot>-bot/responder-debug.log
sudo grep -c '^=====' /home/azureuser/.<bot>-bot/responder-debug.log
sudo tail -40 /home/azureuser/.<bot>-bot/responder-debug.log
```

## Decision tree from the error-log pattern

**Pattern A — rate limit (transient):**

```
2026-MM-DDTHH:MM:SS  claude rc=1: You've hit your limit · resets <time>
2026-MM-DDTHH:MM:SS  L#### first attempt failed; retry...
2026-MM-DDTHH:MM:SS  L#### empty reply (retry also failed)
```

**Action:** wait. Don't touch anything. Verify with:

```bash
TOK=$(sudo cat /proc/$(systemctl show <bot>-bot.service --property=MainPID --value)/environ | tr '\0' '\n' | grep '^CLAUDE_CODE_OAUTH_TOKEN=' | cut -d= -f2-)
curl -sS -w '%{http_code}\n' -o /dev/null -X POST https://api.anthropic.com/v1/messages \
  -H "Authorization: Bearer $TOK" -H "anthropic-version: 2023-06-01" -H "anthropic-beta: oauth-2025-04-20" -H "Content-Type: application/json" \
  -d '{"model":"claude-opus-4-7","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'
```

HTTP 429 = rate limit. HTTP 200 = not rate limit, move to Pattern B.

**Pattern B — the function is broken (persistent):**

```
(no `claude rc=` lines)
(no `claude timeout` lines)
(no `claude spawn:` lines)
(no `claude rate-limited:` lines)
2026-MM-DDTHH:MM:SS  L#### first attempt failed; retry...
2026-MM-DDTHH:MM:SS  L#### empty reply (retry also failed)
```

PLUS: `responder-debug.log` mtime hasn't updated since responder restart (no `===== TIMESTAMP priv=... (claude) =====` entries from after the most recent service start).

That combination means: `run_codex()` is returning `None` without ever calling subprocess. The bot tried to talk to Claude, but the function shorted before it got there.

**Pattern C — Graph 404 (red herring):**

```
2026-MM-DDTHH:MM:SS  graph GET https://graph.microsoft.com/v1.0/chats/a%3A...: HTTP Error 404
```

This is **not the cause**. Personal 1:1 chats (`a:` prefix) can't be fetched via Graph application permissions; the responder logs the 404 and falls back gracefully. If you see this AND Pattern B, ignore the 404 and focus on Pattern B.

## Fixing Pattern B: auto-injection broke the function

Auto-injection scripts (e.g., the `DR_YOO_IDENTIFIERS_V2_VAULT` injection in `mskai-responder.py`) sometimes paste a top-level function definition into the middle of an existing function, dedenting to column 0. Python parses this as the outer function terminating early, leaving everything after the inject orphaned (dead code at wrong indent, attached to a different scope, or just gone).

**Find injections:**

```bash
sudo grep -nE '^# === [A-Z_]+_V[0-9]+(_VAULT)? BEGIN' /home/azureuser/<bot>-responder.py
sudo grep -nE '^# === [A-Z_]+_V[0-9]+(_VAULT)? END' /home/azureuser/<bot>-responder.py
sudo grep -nE '^# === [A-Z_]+(_REBIND)? \(auto-injected' /home/azureuser/<bot>-responder.py
```

If any of those markers land **inside** the indentation range of an existing function (look at the surrounding lines — column-0 code where an indented function body should continue is the smoking gun), the injection broke that function.

**Repair (safe pattern):**

```bash
SCRIPT=/home/azureuser/<bot>-responder.py
sudo cp -p $SCRIPT $SCRIPT.bak-$(date +%s)
sudo python3 <<'PY'
import re
src = open('/home/azureuser/<bot>-responder.py').read()
# Remove every auto-injected BEGIN..END block
# (the pattern uses the exact marker text — adjust per the injection name)
new = re.sub(
    r'^# === [A-Z_]+_V[0-9]+(?:_VAULT)? BEGIN.*?^# === [A-Z_]+_V[0-9]+(?:_VAULT)? END[^\n]*\n',
    '', src, flags=re.DOTALL|re.MULTILINE)
# Also drop the REBIND tail if present
new = re.sub(
    r'^# === [A-Z_]+_V[0-9]+(?:_VAULT)?(?:_REBIND)? \(auto-injected\)[^\n]*\n.*?^# === [A-Z_]+_V[0-9]+(?:_VAULT)?(?:_REBIND)? END[^\n]*\n',
    '', new, flags=re.DOTALL|re.MULTILINE)
# Verify it still parses
try:
    compile(new, 'mskai-responder.py', 'exec')
    open('/home/azureuser/<bot>-responder.py','w').write(new)
    print(f"saved ({len(src)} -> {len(new)} bytes)")
except SyntaxError as e:
    print(f"DID NOT SAVE — would have broken syntax at line {e.lineno}: {e.msg}")
PY
sudo systemctl restart <bot>-responder.service
sleep 5
sudo tail -5 /home/azureuser/.<bot>-bot/responder-debug.log
# Have user send a test message in Teams; debug log should now grow with
# `===== ... (claude) =====` blocks per call.
```

**DO NOT:**

- copy one bot's `/etc/claude-tokens/*.env` onto another's (clobbers identity, mixes Anthropic quota)
- restart things repeatedly hoping it'll resolve (Pattern B is persistent in source code)
- delete the bot's `.credentials.json` or the per-bot env file as a "fix"
- retry dispatching to the same VM extension over and over (see `docs/teams-app-publishing.md` Rule 5 for what *that* trap looks like)

## Distinguishing Anthropic from Graph from code

If you only remember three things:

| What you see | What it means | Action |
|---|---|---|
| `claude rc=1: You've hit your limit` in `responder-errors.log` | Rate limit at Anthropic side | Wait (1h+) |
| `responder-debug.log` mtime hasn't moved since the latest "responder started" line | Code path skipped `subprocess.run` entirely; function broken by injection | Source repair |
| `graph GET .../chats/a%3A...: 404` | Cosmetic; the responder works around it | Ignore unless paired with a real failure |

## Why rate limits are org-level

All MSO bot OAuth tokens are minted under one Anthropic organization (`9b4307a7-f328-4cae-90f9-ab85949b9320`). Per-bot env-file isolation gives each bot its own auth credential but **does not** give it its own rate-limit budget. If one bot trips the org cap, all bots see 429s. If you need per-bot quota isolation, that's a billing change (separate Anthropic accounts or API keys), not a code change.

## Lessons from 2026-05-14

- One bot stayed broken all day because the `DR_YOO_IDENTIFIERS_V2_VAULT` injection landed mid-function in `mskai-responder.py`, terminating `run_codex` at the `import os` line and orphaning the actual Claude call.
- Symptoms looked exactly like rate limit — but rate limit alone would have left `responder-debug.log` entries (the rate-limit message gets logged BEFORE the return None). The empty debug log is the key tell.
- Copying lia.env over mskai.env "to fix it" silently locked the Claude bot (which is supposed to be org-wide-open) to Lia's AAD only, AND made mskai's quota usage count against Lia's token. Don't do that.
