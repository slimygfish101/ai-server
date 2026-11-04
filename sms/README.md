# ClaudePC texting (Google Voice relay)

Built in a separate chat on Nov 4, 2026, handed over through the ClaudePC Project Notes doc,
then reviewed here: added a check that only accepts texts Google really signed (DKIM).

Flow: your cell texts the Google Voice number → Google Voice emails it to the Gmail that owns
the number → `sms_relay.py` on ClaudePC (signed in to that Gmail with an app password) hears it
instantly, ignores anything not from your cell or not signed by Google, replies "Got it", asks
Claude Code, and emails the answer to the Google Voice reply address, which Google Voice delivers
as a text.

Tested Nov 4, 2026: Google Voice rejects replies sent from any other Gmail ("Address not found"),
so replies must come from the owner's Gmail. Chosen setup (user's call): the relay uses the owner's
Gmail directly. Alternative kept in `send-as-me/`: a Google script that can only send Google Voice
replies, for setups where the relay reads a different Gmail.

- `sms_relay.py` – the listener (`--test` checks Gmail and Claude Code)
- `install.ps1` – installs Python, Git and Claude Code for the ClaudeDesk account and the start-up launcher
- `config.example.ini` – settings template; the real `config.ini` is filled in on ClaudePC only
- `chat/CLAUDE.md` – texting rules for Claude
- `tests/test_relay.py` – 20 checks against a pretend Gmail and Claude (`pip install aiosmtpd`, Linux/Mac)
- `send-as-me/Code.gs` – optional send-only Google script (see above)
- `optional/` – an alternative free Google Apps Script version (not used)

