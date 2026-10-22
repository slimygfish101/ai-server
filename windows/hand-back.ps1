# "Hand back to Claude": moves this screen from your Windows App connection back
# onto the computer's own built-in screen, so it stays awake and Claude keeps
# working after you leave. Your Windows App will say the session ended; that's expected.
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden `
    -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}
$session = (Get-Process -Id $PID).SessionId
& "$env:windir\System32\tscon.exe" $session /dest:console
