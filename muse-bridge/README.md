# Muse Bridge

Watches Gmail for new emails with "@muse" in the subject (also "@muse4215" etc.) and pastes each
one into Muse's website chat ("Main chat"), then adds the Gmail label MUSE-HANDLED.

- Gmail: IMAP IDLE (instant), 20-second refresh cycles; if IDLE misbehaves it checks every 30 s.
- Muse: Playwright with its own saved browser profile (`browser-profile\`), Google Chrome, no window.
- Never twice: the MUSE-HANDLED label plus its own list (`handled.json`). Emails already in the
  inbox when it first starts are left alone.
- Problems (Muse logged out, message box missing, Gmail won't connect) email you from your Gmail
  to yourself with the subject "Muse Bridge problem" (at most once an hour per problem).
  Emails that couldn't be sent are retried every 30 s.
- Log: `bridge.log`. Settings: `.env` (password typed on the PC only).

Desktop shortcuts: Muse Bridge - start / stop / log / settings / sign in to Muse.
Install or update: `install.ps1`. Tests: `python tests/test_bridge.py` (pretend Gmail and Muse page).
