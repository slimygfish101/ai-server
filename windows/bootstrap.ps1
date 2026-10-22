# First-boot setup for ClaudePC. Runs once as SYSTEM from the EC2 user data.
# Log: C:\ClaudePC\logs\bootstrap.log   Result: C:\ClaudePC\setup-status.txt
param(
  [Parameter(Mandatory)] [string] $RepoRaw,
  [string] $DeskUser = 'ClaudeDesk',
  [string] $PasswordParam = '/claude-pc/desk-password',
  [string] $Region = 'us-east-1'
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Root = 'C:\ClaudePC'
New-Item -ItemType Directory -Force "$Root\logs", "$Root\downloads", "$Root\work" | Out-Null
Start-Transcript -Path "$Root\logs\bootstrap.log" -Append
$problems = @()
function Step($text) { Write-Host "`n=== $text ===" }
function Problem($text) { Write-Warning $text; $script:problems += $text }

Step 'Download helper scripts'
foreach ($f in 'idle-watch.ps1', 'on-logon.ps1', 'hand-back.ps1', 'set-helper.ps1', 'CLAUDE-RULES.md') {
  try { Invoke-WebRequest -UseBasicParsing "$RepoRaw/windows/$f" -OutFile "$Root\$f" }
  catch { Problem "Could not download $f : $_" }
}
Copy-Item "$Root\CLAUDE-RULES.md" "$Root\work\CLAUDE.md" -Force -ErrorAction SilentlyContinue
if (-not (Test-Path "$Root\helper.txt")) { Set-Content "$Root\helper.txt" 'muse' }

Step 'Desk user account'
try {
  Import-Module AWSPowerShell -ErrorAction SilentlyContinue
  $pw = (Get-SSMParameter -Name $PasswordParam -WithDecryption $true -Region $Region).Value
} catch { Problem "Could not read the desk password: $_" }
if ($pw) {
  $secure = ConvertTo-SecureString $pw -AsPlainText -Force
  if (-not (Get-LocalUser -Name $DeskUser -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $DeskUser -Password $secure -PasswordNeverExpires -FullName 'Claude Desk' | Out-Null
  } else {
    Set-LocalUser -Name $DeskUser -Password $secure
  }
  Add-LocalGroupMember -Group 'Administrators' -Member $DeskUser -ErrorAction SilentlyContinue
  Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $DeskUser -ErrorAction SilentlyContinue
}
# Nobody knows the built-in Administrator's password; switch it off so it can't be guessed at.
Disable-LocalUser -Name 'Administrator' -ErrorAction SilentlyContinue
# Lock an account for 15 minutes after 10 wrong passwords.
net accounts /lockoutthreshold:10 /lockoutwindow:15 /lockoutduration:15 | Out-Null

Step 'Windows settings'
Set-TimeZone -Id 'Eastern Standard Time'
$ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
New-Item -Force $ts | Out-Null
Set-ItemProperty $ts fSingleSessionPerUser 1 -Type DWord   # reconnect to the same screen, never a new desktop
Set-ItemProperty $ts MaxDisconnectionTime 0 -Type DWord     # never log off a disconnected screen
Set-ItemProperty $ts MaxIdleTime 0 -Type DWord
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' UserAuthentication 1 -Type DWord
$sys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Set-ItemProperty $sys InactivityTimeoutSecs 0 -Type DWord
# No "are you sure?" pop-ups: Claude can't click those, they sit on a protected screen.
Set-ItemProperty $sys ConsentPromptBehaviorAdmin 0 -Type DWord
Set-ItemProperty $sys PromptOnSecureDesktop 0 -Type DWord
$pers = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
New-Item -Force $pers | Out-Null
Set-ItemProperty $pers NoLockScreen 1 -Type DWord
$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Force $wu | Out-Null
Set-ItemProperty $wu NoAutoRebootWithLoggedOnUsers 1 -Type DWord
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\ServerManager' DoNotOpenServerManagerAtLogon 1 -Type DWord -ErrorAction SilentlyContinue
Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0

Step 'Virtualization features for Cowork'
try { Install-WindowsFeature -Name Hyper-V -IncludeManagementTools | Out-Null } catch { Problem "Hyper-V: $_" }
foreach ($feat in 'VirtualMachinePlatform', 'HypervisorPlatform') {
  try { Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart | Out-Null }
  catch { Problem "$feat : $_" }
}

Step 'Google Chrome'
try {
  $msi = "$Root\downloads\chrome.msi"
  Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi' -OutFile $msi
  Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
} catch { Problem "Chrome: $_" }
# Pre-install the Claude in Chrome extension (still removable).
$chrome = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
New-Item -Force $chrome | Out-Null
$ext = '{"fcoeoabgfenejglbffodgkkbkcdhcgfn":{"installation_mode":"normal_installed","update_url":"https://clients2.google.com/service/update2/crx"}}'
Set-ItemProperty $chrome ExtensionSettings $ext -Type String
Set-ItemProperty $chrome PasswordManagerEnabled 1 -Type DWord

Step 'Claude desktop app'
try {
  $msix = "$Root\downloads\Claude.msix"
  Invoke-WebRequest -UseBasicParsing 'https://claude.ai/api/desktop/win32/x64/msix/latest/redirect' -OutFile $msix
  Add-AppxProvisionedPackage -Online -PackagePath $msix -SkipLicense | Out-Null
} catch { Problem "Claude app: $_" }

Step 'Automatic sign-in to the desk account'
if ($pw) {
  try {
    Invoke-WebRequest -UseBasicParsing 'https://download.sysinternals.com/files/AutoLogon.zip' -OutFile "$Root\downloads\AutoLogon.zip"
    Expand-Archive "$Root\downloads\AutoLogon.zip" "$Root\downloads\AutoLogon" -Force
    & "$Root\downloads\AutoLogon\Autologon64.exe" /accepteula $DeskUser $env:COMPUTERNAME $pw | Out-Null
  } catch { Problem "Autologon: $_" }
}
Remove-Variable pw, secure -ErrorAction SilentlyContinue

Step 'Start-up task (Claude app + 60-minute idle timer)'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $Root\on-logon.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$DeskUser"
$principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$DeskUser" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'ClaudePC-OnLogon' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Step 'Desktop icons'
$shell = New-Object -ComObject WScript.Shell
function Shortcut($name, $script, $extra, $icon) {
  $s = $shell.CreateShortcut("C:\Users\Public\Desktop\$name.lnk")
  $s.TargetPath = 'powershell.exe'
  $s.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $Root\$script $extra"
  $s.IconLocation = $icon
  $s.Save()
}
Shortcut 'Hand back to Claude' 'hand-back.ps1' '' 'imageres.dll,101'
Shortcut 'Helper - use Meta Muse first' 'set-helper.ps1' 'muse' 'imageres.dll,77'
Shortcut 'Helper - use Grok first' 'set-helper.ps1' 'grok' 'imageres.dll,77'
$s = $shell.CreateShortcut('C:\Users\Public\Desktop\Claude rules.lnk')
$s.TargetPath = 'notepad.exe'; $s.Arguments = "$Root\CLAUDE-RULES.md"; $s.Save()

Step 'Finished'
$status = if ($problems.Count) { "done with problems:`r`n" + ($problems -join "`r`n") } else { 'done' }
Set-Content "$Root\setup-status.txt" "$status`r`n$(Get-Date -Format s)"
Stop-Transcript
# Restart to switch on the virtualization features; it then signs in to the desk account by itself.
shutdown.exe /r /t 30 /c "ClaudePC setup finished, restarting"
