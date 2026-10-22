# Runs every time the desk account signs in (including the automatic sign-in after power-on).
$Root = 'C:\ClaudePC'
Start-Transcript -Path "$Root\logs\on-logon.log" -Append | Out-Null

# Keep the screen awake: no screen saver, no lock.
Set-ItemProperty 'HKCU:\Control Panel\Desktop' ScreenSaveActive '0'
Set-ItemProperty 'HKCU:\Control Panel\Desktop' ScreenSaverIsSecure '0'

# Open the Claude desktop app.
$pkg = Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' } | Select-Object -First 1
if ($pkg) {
  $appId = (Get-AppxPackageManifest $pkg).Package.Applications.Application.Id | Select-Object -First 1
  Start-Process "shell:AppsFolder\$($pkg.PackageFamilyName)!$appId"
} else {
  Write-Warning 'Claude desktop app not found'
}

Stop-Transcript | Out-Null
# The idle timer runs for as long as this sign-in lasts.
& "$Root\idle-watch.ps1"
