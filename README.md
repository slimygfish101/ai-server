# ClaudePC: a Windows cloud computer for Claude

A Windows computer rented from Amazon (AWS) that Claude works on by itself.
You can look at and use the same screen from your iPad or PC whenever you want.

## What you get

| Piece | What it does |
|---|---|
| **The computer** | Windows Server 2025 (looks like Windows 11), size `m7i-flex.large` (2 processors, 8 GB memory, 80 GB disk) in Amazon's Ohio location (where your Amazon project lives). Set up so Claude's Cowork feature can control the whole screen. |
| **On/off** | Claude (in your Claude app chats) can turn it on and off. It also **switches itself off after 60 minutes with no activity**, with a 5-minute warning first. If that ever fails, a backup on Amazon's side switches it off after 2 quiet hours. |
| **Software** | Chrome, the Claude in Chrome extension, and the Claude desktop app (opens by itself at start-up). |
| **Your access** | Connect with Microsoft's free **Windows App**. You land on the exact screen Claude is using. |
| **Helpers** | Meta Muse (first choice) and Grok, both logged in through Chrome. Switch with the desktop icons. |
| **Rules for Claude** | [`windows/CLAUDE-RULES.md`](windows/CLAUDE-RULES.md): do it yourself first, hand off to the helper only when blocked, check the helper's work, keep passwords out of chats, call you for anything only a human can do. |
| **Money alerts** | Emails when about $50 of credit is left (and again at $20), the moment any real charge appears, at $8 of real charges, and when Amazon predicts you'll pass $10. |

## Cost (Ohio prices, October 2026)

- **About 18¢ per hour while it's on** (includes the Windows licence).
- **About $10 a month even while it's off**: about $6.40 for the 80 GB disk, plus about $3.65 for the fixed internet address.
- Example: 3 hours a day ≈ $26 a month, paid from your Amazon credits.

On Amazon's **Free plan** your card is never charged; if credits run out, Amazon pauses the account instead.

## Desktop icons on the cloud computer

- **Hand back to Claude**: use this when you're done, *instead of* just closing the Windows App. It keeps the screen "awake" so Claude can keep working. The Windows App will then say the session ended; that's normal.
- **Helper - use Meta Muse first** / **Helper - use Grok first**: picks which helper Claude asks first.
- **Claude rules**: opens Claude's rulebook.

## Setup steps

1. **You:** create the Amazon account (Free plan).
2. **You:** open **CloudShell** (the `>_` icon at the top of the Amazon website, with the location set to "Ohio"), then paste:
   ```
   curl -fsSL https://raw.githubusercontent.com/slimygfish101/ai-server/refs/heads/claude/aws-cloud-computer-setup-jin2ax/setup/aws-setup.sh -o aws-setup.sh
   bash aws-setup.sh YOUR-EMAIL 100
   ```
   (`100` = dollars of credit you have; change it if Amazon shows a different amount.)
3. **You:** the script prints two things:
   - the **PC address, user name and password**: save them only in the Windows App;
   - Claude's **on/off key**: put it in the Claude environment settings, never in the chat.
4. **Wait 20–30 minutes** while the computer installs everything and restarts itself.
5. **You:** connect once with the Windows App to sign in to Claude, Chrome, Meta Muse and Grok yourself.
6. **Claude:** checks the setup, tests Cowork, and fixes anything that didn't work.

## Files

- `setup/aws-setup.sh`: one-time Amazon setup (run in CloudShell). Safe to run again.
- `windows/bootstrap.ps1`: first-start installer that runs on the cloud computer.
- `windows/idle-watch.ps1`: the 60-minute auto-off timer.
- `windows/hand-back.ps1`, `windows/set-helper.ps1`, `windows/on-logon.ps1`: desktop icons and the start-up routine.
- `tools/pc.sh`: what Claude uses from chat to turn the computer on/off and check on it.

## Good to know

- Remote Desktop is open to the internet so you can connect from anywhere (home, phone data). It's protected by a long random password, an unusual user name, the built-in Administrator account being switched off, and a 15-minute lock-out after 10 wrong guesses.
- Anthropic doesn't officially list Windows Server as supported for Cowork. The setup switches on everything Cowork needs; Claude will test it on first start.
- "Real charge" emails come from Amazon's budget system, which updates a few times a day, so an alert can arrive several hours after the charge.
