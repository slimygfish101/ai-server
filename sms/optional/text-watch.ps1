# Texting: picks up your texts from the Google relay, hands them to Claude Code
# on this PC, and texts the answers back. Started by on-logon.ps1.
# Needs C:\ClaudePC\text-relay.txt with 2 lines: the relay's web app address, then its secret.
# Text "new" to start a fresh conversation; otherwise Claude remembers the last one.
$Root = 'C:\ClaudePC'
$log  = "$Root\logs\text-watch.log"
$cfg  = "$Root\text-relay.txt"
function Log($m) { Add-Content $log "$(Get-Date -Format s) $m" }
function Touch { Set-Content "$Root\last-text.txt" (Get-Date -Format s) }  # keeps the 60-minute auto-off from firing mid-chat

while (-not (Test-Path $cfg)) { Start-Sleep 60 }
$lines  = @(Get-Content $cfg | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$url    = $lines[0]
$secret = $lines[1]

function Relay($body) {
  $body.secret = $secret
  $json = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress))
  Invoke-RestMethod -Method Post -Uri $url -Body $json -ContentType 'application/json; charset=utf-8' -TimeoutSec 60
}
function Send-Text($t) { try { Relay @{ action = 'reply'; text = $t } | Out-Null } catch { Log "reply failed: $_" } }

$sms = 'Lipa is texting you from his phone; your reply goes back to him as a text message. ' +
       'Plain text only (no markdown, no tables), short and simple, under 600 characters unless he asks for more. ' +
       'Follow the rules in CLAUDE.md. If you need him to do something (a code, a CAPTCHA, an approval, a payment), say exactly what.'
$utf8 = New-Object Text.UTF8Encoding $false
$fresh = $false
Log 'started'

while ($true) {
  try { $r = Relay @{ action = 'poll' } } catch { Log "poll failed: $_"; Start-Sleep 30; continue }
  foreach ($m in @($r.messages)) {
    if (-not $m -or -not $m.text) { continue }
    Touch
    $text = "$($m.text)".Trim()
    if ($text -match '^(new|new chat|start over)\W*$') { $fresh = $true; Send-Text 'OK, your next text starts a fresh conversation.'; continue }

    $claude = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claude) { $claude = Get-Item "$env:USERPROFILE\.local\bin\claude.exe" -ErrorAction SilentlyContinue }
    if (-not $claude) { Send-Text 'Claude Code is not set up on the PC yet. Connect once from your iPad and sign in.'; continue }
    $exe = if ($claude.Source) { $claude.Source } else { $claude.FullName }

    $in = "$Root\logs\text-in.txt"; $out = "$Root\logs\text-out.txt"; $err = "$Root\logs\text-err.txt"
    [IO.File]::WriteAllText($in, $text, $utf8)
    $cargs = @('-p', '--dangerously-skip-permissions', '--chrome', '--append-system-prompt', "`"$sms`"")
    if (-not $fresh) { $cargs = @('--continue') + $cargs }
    $fresh = $false
    Log "-> $text"

    $p = Start-Process -FilePath $exe -ArgumentList $cargs -WorkingDirectory "$Root\work" -NoNewWindow -PassThru `
         -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err
    $started = Get-Date; $nudged = $false
    while (-not $p.HasExited) {
      Start-Sleep 15; Touch
      if (-not $nudged -and ((Get-Date) - $started).TotalSeconds -gt 90) { Send-Text 'Working on it...'; $nudged = $true }
      if (((Get-Date) - $started).TotalMinutes -gt 45) { $p.Kill(); Send-Text 'That took over 45 minutes, so I stopped it. Text me to try again or split it up.'; break }
    }
    $answer = (Get-Content $out -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($answer) { $answer = $answer.Trim() }
    if (-not $answer) {
      Log "no answer; error: $(Get-Content $err -Raw -ErrorAction SilentlyContinue)"
      $answer = 'Something went wrong on the PC and Claude gave no answer. Text "new" and try again.'
    }
    Log "<- $($answer.Length) chars"
    Send-Text $answer
    Touch
  }
  Start-Sleep 10
}
