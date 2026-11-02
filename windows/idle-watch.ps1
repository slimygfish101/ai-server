# Switches the computer off (which "stops" it on Amazon, so billing stops) after
# 60 minutes with no mouse/keyboard activity from you or Claude, as long as the
# computer isn't busy. To keep it on during a long hands-off job, save any text
# into C:\ClaudePC\stay-on.txt (counts for 3 hours from when it was last saved).
param([int] $IdleMinutes = 60, [int] $WarnMinutes = 55, [int] $BusyCpuPercent = 25)
$Root = 'C:\ClaudePC'
$log = "$Root\logs\idle-watch.log"

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class IdleClock {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
  public static double Minutes() {
    var info = new LASTINPUTINFO(); info.cbSize = (uint)Marshal.SizeOf(info);
    GetLastInputInfo(ref info);
    return unchecked((uint)Environment.TickCount - info.dwTime) / 60000.0;
  }
}
'@

function Stop-AzureSelf {
  $imds = @{ Metadata = 'true' }
  $token = (Invoke-RestMethod -Headers $imds -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/').access_token
  $vm = Invoke-RestMethod -Headers $imds -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01'
  $uri = "https://management.azure.com/subscriptions/$($vm.subscriptionId)/resourceGroups/$($vm.resourceGroupName)" +
         "/providers/Microsoft.Compute/virtualMachines/$($vm.name)/deallocate?api-version=2024-07-01"
  Invoke-RestMethod -Method Post -Headers @{ Authorization = "Bearer $token" } -Uri $uri | Out-Null
}

$warned = $false
while ($true) {
  Start-Sleep -Seconds 60
  $idle = [IdleClock]::Minutes()
  if ($idle -lt $WarnMinutes) { $warned = $false; continue }

  $stayOn = Get-Item "$Root\stay-on.txt" -ErrorAction SilentlyContinue
  if ($stayOn -and $stayOn.LastWriteTime -gt (Get-Date).AddHours(-3)) { continue }

  if (-not $warned) {
    msg.exe * /time:300 "ClaudePC will switch itself off in about 5 minutes because nobody is using it. Move the mouse to keep it on."
    $warned = $true
    continue
  }
  if ($idle -lt $IdleMinutes) { continue }

  $cpu = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 5 -MaxSamples 6 -ErrorAction SilentlyContinue).CounterSamples |
         Measure-Object CookedValue -Average | Select-Object -ExpandProperty Average
  if ($cpu -ge $BusyCpuPercent) { continue }

  Add-Content $log "$(Get-Date -Format s) idle $([int]$idle) min, cpu $([int]$cpu)% -> switching off"
  if ((Get-Content "$Root\cloud.txt" -ErrorAction SilentlyContinue) -eq 'azure') {
    # On Azure, shutting Windows down keeps the computer reserved and billed;
    # only a "deallocate" request to Azure stops the charges.
    try { Stop-AzureSelf; break }
    catch { Add-Content $log "$(Get-Date -Format s) Azure deallocate failed: $_" }
  }
  shutdown.exe /s /t 30 /c "ClaudePC: unused for $IdleMinutes minutes, switching off to save money"
  break
}
