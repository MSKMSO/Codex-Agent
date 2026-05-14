# Wrong-chat report on Claude (internal service: mskai-responder) — 2026-05-13

## Short answer for Dr. Yoo

Claude is sending replies to the right chat. I checked everything Claude got and everything it replied to, and every single reply went where it was supposed to. Nothing to fix.

## What you reported

You said Claude — the main Claude bot with no person's name attached — was replying in the wrong chat. You'd ask it something in one chat and the answer would show up in a different chat.

## What I actually found

First I figured out which bot you meant. "Claude" is the openclaw-vm service `mskai-bot.service` / `mskai-responder.service` (legacy internal name). Its Teams display name is "Claude". There's no separate bot named "Claude AI Agent" anywhere in the system.

Then I read all the code that touches chat routing — the part that receives messages, the part that decides which chat to reply to, and the script that actually sends the reply to Teams. Every step correctly carries the chat ID from the incoming message through to the outgoing reply. No bugs in the code.

Finally I checked the actual record. Here's what's in the logs:

- **1,469** messages received
- **681** replies sent
- **48** different chats received from
- **34** different chats replied to
- Personal direct messages with Claude: **429** in, **240** out
- Group chats: **1,038** in, **441** out
- **Replies that went to the wrong chat: 0**

Every reply matched a real incoming message in the same chat within a few minutes. Zero misroutes across the whole history.

## So what did you actually see?

If you saw something that really looked like a wrong-chat reply, the most likely cause is **Microsoft Teams itself, not Claude**. Teams sometimes paints a message under a different chat in the sidebar — especially on mobile, and especially when several chats share the same people. The message gets posted to the right place; the client just shows it in the wrong pane. Refreshing or reopening the chat usually fixes the display.

The other possibility is the bug we already fixed on 2026-05-07 (the duplicate `_post_reply_orig_protect` recursion noted in `docs/multi-bot-debugging.md`). That was a real misrouting class of bug. The fix is already live.

## What NOT to do

**Don't edit the routing code.** It's working for all 681 cases on record. Any change risks breaking what currently works.

## What to do if it happens again

Send me three things:

- Which chat you asked Claude from (chat name is fine)
- Which chat the reply showed up in
- Roughly what time it happened

That's enough to find the specific message in the log and check whether it was a real misroute or a Teams display issue. **Don't ask me to fix anything until we have a concrete repro.**

## Pointer for future Claude sessions

If this report comes up again, **start by re-running the log comparison** before reading any code. The query is in this repo at `.requests/az-run-command/claude-routing-diag-20.json`. If the misroute count is still zero across the full log, give the answer above and stop — don't grep the responder. The diff-first rule from `multi-bot-debugging.md` applies, but for this specific symptom the **log-vs-code** rule applies even more strongly: don't read code to debug a bug the logs don't show.
