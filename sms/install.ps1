# ClaudePC texting installer. Run as ClaudeDesk (no admin needed):
#   powershell -ExecutionPolicy Bypass -File C:\ClaudePC\sms\install.ps1
$ErrorActionPreference = 'Stop'
$Sms = 'C:\ClaudePC\sms'
New-Item -ItemType Directory -Force -Path $Sms, "$Sms\chat", 'C:\ClaudePC\work' | Out-Null
if ($PSScriptRoot -and ($PSScriptRoot -ne $Sms)) {
    Copy-Item "$PSScriptRoot\*" $Sms -Recurse -Force
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'Machine') + ";$env:USERPROFILE\.local\bin"
}
function Find-Python {
    Refresh-Path
    foreach ($c in @("$env:LOCALAPPDATA\Programs\Python\Python314\python.exe",
                     "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
                     "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe")) {
        if (Test-Path $c) { return $c }
    }
    $p = Get-Command python.exe -ErrorAction SilentlyContinue |
         Where-Object { $_.Source -notlike '*WindowsApps*' } | Select-Object -First 1
    if ($p) { return $p.Source }
    return $null
}

# 1. Python (just for this user)
$py = Find-Python
if (-not $py) {
    Write-Host 'Installing Python...'
    $ok = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Python.Python.3.14 --scope user --silent --accept-package-agreements --accept-source-agreements | Out-Host
        $py = Find-Python; $ok = [bool]$py
    }
    if (-not $ok) {
        $inst = "$env:TEMP\python-installer.exe"
        Invoke-WebRequest 'https://www.python.org/ftp/python/3.14.0/python-3.14.0-amd64.exe' -OutFile $inst
        Start-Process $inst -ArgumentList '/quiet InstallAllUsers=0 PrependPath=1 Include_launcher=0' -Wait
        $py = Find-Python
    }
    if (-not $py) { throw 'Python install failed' }
}
$pyw = Join-Path (Split-Path $py) 'pythonw.exe'
Write-Host "Python: $py"

# 2. Git (Claude Code uses it) and Claude Code (just for this user)
Refresh-Path
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host 'Installing Git...'
        winget install --id Git.Git --scope user --silent --accept-package-agreements --accept-source-agreements | Out-Host
        Refresh-Path
    }
}
if (-not (Get-Command claude.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing Claude Code...'
    Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    Refresh-Path
}
$claude = (Get-Command claude.exe -ErrorAction SilentlyContinue).Source
if (-not $claude) { $claude = "$env:USERPROFILE\.local\bin\claude.exe" }
Write-Host "Claude Code: $claude"

# Codex (the ChatGPT fallback) reads AGENTS.md; give it the same texting rules
Copy-Item "$Sms\chat\CLAUDE.md" "$Sms\chat\AGENTS.md" -Force

# 3. Settings file (you fill in the password yourself; it never goes in a chat)
if (-not (Test-Path "$Sms\config.ini")) {
    Copy-Item "$Sms\config.example.ini" "$Sms\config.ini"
}
$cfg = Get-Content "$Sms\config.ini" -Raw
if ($cfg -notmatch 'claude_command') {
    Add-Content "$Sms\config.ini" "claude_command = $claude"
}

# 4. Keep-alive launcher: restarts the listener if it ever stops; starts at sign-in
$loop = "@echo off`r`n:loop`r`n`"$py`" `"$Sms\sms_relay.py`"`r`ntimeout /t 15 /nobreak >nul`r`ngoto loop`r`n"
Set-Content "$Sms\run-relay.cmd" $loop -Encoding ASCII
$vbs = "CreateObject(`"WScript.Shell`").Run `"cmd /c `"`"$Sms\run-relay.cmd`"`"`", 0, False"
Set-Content "$Sms\start-relay.vbs" $vbs -Encoding ASCII
$startup = [Environment]::GetFolderPath('Startup')
Copy-Item "$Sms\start-relay.vbs" "$startup\ClaudePC-texting.vbs" -Force

Write-Host ''
Write-Host 'Installed. Next:'
Write-Host "  1. Fill in $Sms\config.ini (Gmail, app password, your cell)."
Write-Host '  2. Run once:  claude   (sign in, then type /exit)'
Write-Host "  3. Test:      `"$py`" $Sms\sms_relay.py --test"
Write-Host "  4. Start:     double-click $Sms\start-relay.vbs  (it also starts by itself at sign-in)"
