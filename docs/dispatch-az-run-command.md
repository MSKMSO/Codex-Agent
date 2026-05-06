# Push-triggered Azure run-command proxy (for MSO Claude Code in this repo)

This MSO Claude Code session has no Azure CLI / no auth tokens / no SSH. To run shell on `openclaw-vm` (or any VM in `SDNeurosurgery-OpenClaw`), use this proxy.

## How

Commit `.requests/az-run-command/<your-id>.json`:

```json
{
  "vm":     "openclaw-vm",
  "rg":     "SDNeurosurgery-OpenClaw",
  "script": "systemctl list-units --type=service --no-pager | grep -iE 'bot|agent'"
}
```

Push triggers the workflow. After ~30–60s, response lands at `.responses/az-run-command/<your-id>.json`:

```json
{
  "vm":        "openclaw-vm",
  "rg":        "SDNeurosurgery-OpenClaw",
  "exit_code": 0,
  "stdout":    "...",
  "stderr":    ""
}
```

Read it back via `get_file_contents`.

## Permissions

Backed by `sp-mso-cc-openclaw-diag` via OIDC federated credential. The SP holds the **OpenClaw Run Command Operator** custom role on `openclaw-vm` only — read VM metadata, run shell scripts, read run-command output. **Cannot** start/stop/delete/modify the VM itself.

If you need to run on a different VM (e.g. `watchdog-vm`), the SP doesn't have access there yet. Tell Dr. Yoo to extend the role assignment.

## Examples

**List bot services:**
```json
{"vm":"openclaw-vm","script":"systemctl list-units --type=service --no-pager | grep -iE 'bot|agent'"}
```

**Tail a bot's log:**
```json
{"vm":"openclaw-vm","script":"journalctl -u zahid-bot -n 50 --no-pager"}
```

**Read a config file:**
```json
{"vm":"openclaw-vm","script":"cat /home/azureuser/.aixa-bot/creds.json | python3 -c 'import sys,json; d=json.load(sys.stdin); print(list(d.keys()))'"}
```

**Restart a service:**
```json
{"vm":"openclaw-vm","script":"sudo systemctl restart neil-responder.service && systemctl status neil-responder.service --no-pager | head -5"}
```

## Cleanup

Old `.requests/`/`.responses/` files accumulate. Delete them after you've read the response, or in batches periodically.
