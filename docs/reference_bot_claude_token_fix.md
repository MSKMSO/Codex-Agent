# Bot Claude auth — token-file fix recipe

## Symptom

All Claude bots reply with either:
- `⚠️ Had trouble generating a reply — please retry in a moment.`
- `Your organization does not have access to Claude.`

## Root cause

The bots share a single OAuth account (`yoomd@sdneurosurgery.com`). When that account loses its subscription claim, **every** Claude-backed bot fails at the same time. Each bot reads its own copy of the token from `/etc/claude-tokens/<prefix>.env`. When one or more of those files becomes empty (truncated to just the header comment), those bots break.

## Quick fix (no manual sign-in needed if at least one bot is healthy)

```bash
# 1. Find the broken token files
ls -la /etc/claude-tokens/*.env
```

Healthy files are **~186–224 bytes**. Broken files are **~53–91 bytes** (just the comment line, no actual token).

```bash
# 2. Copy a healthy token file onto each short one
sudo cp -p /etc/claude-tokens/lia.env /etc/claude-tokens/<prefix>.env
```

`lia.env` and `cameron.env` are good source candidates. Filenames use **hyphens** — i.e. `neil-claude.env` not `neilc.env`, `jesus-reyes.env` not `jesusr.env`.

```bash
# 3. Restart the affected responder
sudo systemctl restart <prefix>-responder.service

# 4. Verify
systemctl is-active <prefix>-responder.service
```

Send a test message in Teams to confirm.

## When the quick fix doesn't apply

If **every** `.env` file is short/missing, the canonical OAuth token has expired across the board. In that case, the only fix is a manual interactive `claude /login` on openclaw-vm as `yoomd@sdneurosurgery.com`. That's the one scenario where browser sign-in is unavoidable.

## Also verify the maintenance cron

```bash
sudo crontab -u azureuser -l | grep claude-cred-chmod
```

If missing, re-add:

```bash
* * * * * /home/azureuser/.claude-cred-chmod.sh >/dev/null 2>&1
```

This keeps the legacy `/home/azureuser/.claude/.credentials.json` at mode 0640 between token rotations.

## Last incident

**2026-05-14:** `gabriel.env`, `heather.env`, and `kaye.env` were 91 bytes each (empty token). Fixed by `cp -p /etc/claude-tokens/lia.env` (224 bytes) onto each, then restarting their `*-responder.service` units.

## TL;DR pointer for next session

1. `ls -la /etc/claude-tokens/*.env`
2. Any file under 100 bytes is broken → copy a healthy one (`lia.env`, `cameron.env`) onto it.
3. Restart the affected `<prefix>-responder.service`.
4. Done. No manual sign-in needed unless EVERY file is short.
