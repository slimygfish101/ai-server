# ClaudePC texting (Google Voice relay)

Built in a separate chat on Nov 4, 2026, handed over through the ClaudePC Project Notes doc,
then reviewed here: added a check that only accepts texts Google really signed (DKIM).

Flow: your cell texts the Google Voice number → Google Voice emails it → a Gmail filter forwards
texts from approved numbers to the ClaudePC Gmail → `sms_relay.py` on ClaudePC hears it instantly,
replies "Got it", asks Claude Code, and emails the answer back to the Google Voice reply address,
which Google Voice delivers as a text.

- `sms_relay.py` – the listener (`--test` checks Gmail and Claude Code)
- `install.ps1` – installs Python, Git and Claude Code for the ClaudeDesk account and the start-up launcher
- `config.example.ini` – settings template; the real `config.ini` is filled in on ClaudePC only
- `chat/CLAUDE.md` – texting rules for Claude
- `tests/test_relay.py` – 20 checks against a pretend Gmail and Claude (`pip install aiosmtpd`, Linux/Mac)
- `optional/` – an alternative free Google Apps Script version (not used)

Open question: whether Google Voice accepts replies sent from the ClaudePC Gmail rather than the
Gmail that owns the Google Voice number. To be tested before going live.
