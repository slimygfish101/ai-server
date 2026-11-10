# Installs Muse Bridge for one Windows user (default: ClaudeDesk on ClaudePC).
# Safe to run again: keeps .env, handled.json, the log and the saved browser profile.
param(
  [string] $User = 'ClaudeDesk',
  [string] $Email = '',
  [string] $Raw = 'https://raw.githubusercontent.com/slimygfish101/ai-server/refs/heads/claude/aws-cloud-computer-setup-jin2ax/muse-bridge',
  [string] $Python = 'C:\Program Files\Python313\python.exe'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Home_ = "C:\Users\$User"
$Dir = "$Home_\muse-bridge"
New-Item -ItemType Directory -Force $Dir | Out-Null

foreach ($f in 'muse_bridge.py', 'README.md', '.env.example') {
  Invoke-WebRequest -UseBasicParsing "$Raw/$f" -OutFile "$Dir\$f"
}

# Its own Python environment with Playwright (uses the installed Google Chrome; no extra browser download)
if (-not (Test-Path "$Dir\venv\Scripts\pythonw.exe")) { & $Python -m venv "$Dir\venv" }
& "$Dir\venv\Scripts\python.exe" -m pip install --quiet --upgrade pip 2>&1 | Out-Null
& "$Dir\venv\Scripts\python.exe" -m pip install --quiet "playwright==1.56.0" tzdata 2>&1 | Out-Null
& "$Dir\venv\Scripts\python.exe" -c "import playwright, tzdata; print('playwright ok')"

# Settings file: the password line stays blank for the user to fill in
if (-not (Test-Path "$Dir\.env")) {
  (Get-Content "$Dir\.env.example") -replace '^GMAIL_ADDRESS=.*$', "GMAIL_ADDRESS=$Email" |
    Set-Content "$Dir\.env" -Encoding ASCII
}

# Keep-alive loop (restarts it if it ever stops) started hidden by a .vbs
Set-Content "$Dir\run-bridge.cmd" -Encoding ASCII -Value @"
@echo off
:loop
"%~dp0venv\Scripts\pythonw.exe" "%~dp0muse_bridge.py"
timeout /t 15 /nobreak >nul
goto loop
"@
Set-Content "$Dir\start-bridge.vbs" -Encoding ASCII -Value "CreateObject(`"WScript.Shell`").Run `"cmd /c `"`"$Dir\run-bridge.cmd`"`"`", 0, False"
Set-Content "$Dir\stop-bridge.ps1" -Encoding ASCII -Value @'
# Stops Muse Bridge: its keep-alive loop, the program and its browser.
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like '*muse-bridge*' -and $_.ProcessId -ne $PID -and $_.CommandLine -notlike '*stop-bridge.ps1*' -and $_.CommandLine -notlike '*sign-in-to-muse*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
'@
Set-Content "$Dir\sign-in-to-muse.cmd" -Encoding ASCII -Value @"
@echo off
echo Stopping Muse Bridge for a moment...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-bridge.ps1"
echo A browser window will open on Muse. Sign in there, then close that browser window.
"%~dp0venv\Scripts\python.exe" "%~dp0muse_bridge.py" --login
echo Starting Muse Bridge again...
wscript "%~dp0start-bridge.vbs"
"@

# Start at sign-in (this user only)
$startup = "$Home_\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
New-Item -ItemType Directory -Force $startup | Out-Null
Copy-Item "$Dir\start-bridge.vbs" "$startup\Muse Bridge.vbs" -Force

# Desktop shortcuts
$desk = "$Home_\Desktop"
New-Item -ItemType Directory -Force $desk | Out-Null
$sh = New-Object -ComObject WScript.Shell
function Link($name, $target, $arguments, $icon) {
  $s = $sh.CreateShortcut("$desk\$name.lnk"); $s.TargetPath = $target; $s.Arguments = $arguments
  $s.WorkingDirectory = $Dir; if ($icon) { $s.IconLocation = $icon }; $s.Save()
}
Link 'Muse Bridge - start' 'wscript.exe' "`"$Dir\start-bridge.vbs`"" 'imageres.dll,101'
Link 'Muse Bridge - stop' 'powershell.exe' "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Dir\stop-bridge.ps1`"" 'imageres.dll,100'
Link 'Muse Bridge - log' 'notepad.exe' "`"$Dir\bridge.log`"" ''
Link 'Muse Bridge - sign in to Muse' "$Dir\sign-in-to-muse.cmd" '' 'imageres.dll,77'
Link 'Muse Bridge - settings' 'notepad.exe' "`"$Dir\.env`"" ''
"installed in $Dir"
