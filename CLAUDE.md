# MSO Claude Code — operational memory

Standing rules and project context live in [`AGENTS.md`](AGENTS.md). Read it first.

## Pointers for common situations

**A bot in Teams replies with "⚠️ Had trouble generating a reply".**
Read [`docs/bot-empty-reply-diagnosis.md`](docs/bot-empty-reply-diagnosis.md) before doing anything else. Diagnose first — do not copy token files between bots, do not restart things repeatedly, do not retry dispatches.

**Other operational playbooks:**
- [`docs/runbook-deploy-new-bot.md`](docs/runbook-deploy-new-bot.md) — adding a new person's bot
- [`docs/dispatch-az-run-command.md`](docs/dispatch-az-run-command.md) — how the proxy works
