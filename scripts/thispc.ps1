# Battery health and sell-readiness for the Windows laptop this runs on.
# Read-only, except -Reset, which opens Windows' own "Reset this PC" dialog
# (you still choose "Remove everything" and confirm there).
# -Wipe starts an unattended "Remove everything + clean drive" reset through the Windows
# MDM RemoteWipe interface (needs admin; runs as SYSTEM). It asks for a typed confirmation
# first and then cannot be stopped. Run it only on the laptop you are about to sell.
param(
  [switch]$Reset,
  [switch]$Wipe,
  [switch]$NoOpenReport
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ReportsDir = Join-Path $Root "reports"
$null = New-Item -ItemType Directory -Force -Path $ReportsDir
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

function Row([string]$Name, $Value, [string]$Flag = "") {
  [pscustomobject]@{ Item = $Name; Value = [string]$Value; Note = $Flag }
}

$rows = New-Object System.Collections.Generic.List[object]
$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$rows.Add((Row "Model" "$($cs.Manufacturer) $($cs.Model)"))
$rows.Add((Row "Serial number" $bios.SerialNumber))
$rows.Add((Row "CPU" $cpu.Name.Trim()))
$rows.Add((Row "RAM" ("{0:N0} GB" -f ($cs.TotalPhysicalMemory / 1GB))))
foreach ($d in Get-CimInstance Win32_DiskDrive) {
  $rows.Add((Row "Disk" ("{0} ({1:N0} GB)" -f $d.Model, ($d.Size / 1GB))))
}
$rows.Add((Row "Windows" "$($os.Caption) $($os.Version)"))

# Battery: Windows' own report, as XML.
$xmlPath = Join-Path $env:TEMP "battery-report-$stamp.xml"
powercfg /batteryreport /xml /output $xmlPath | Out-Null
if (Test-Path -LiteralPath $xmlPath) {
  [xml]$x = Get-Content -LiteralPath $xmlPath -Raw
  foreach ($b in $x.BatteryReport.Batteries.Battery) {
    $design = [double]$b.DesignCapacity
    $full = [double]$b.FullChargeCapacity
    $health = if ($design -gt 0) { [math]::Round($full / $design * 100, 1) } else { $null }
    $rows.Add((Row "Battery" "$($b.Manufacturer) $($b.Id)"))
    $rows.Add((Row "Maximum capacity" "$health %  ($([math]::Round($full/1000,1)) of $([math]::Round($design/1000,1)) Wh)" $(if ($health -and $health -lt 80) { "below 80%" } else { "" })))
    $rows.Add((Row "Cycle count" $b.CycleCount))
  }
  Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
} else {
  $rows.Add((Row "Battery" "no battery report (desktop PC?)"))
}

# Things that must be undone before selling.
$blockers = @()
$msa = Get-ChildItem "HKCU:\Software\Microsoft\IdentityCRL\StoredIdentities" -ErrorAction SilentlyContinue
if ($msa) {
  $blockers += "Microsoft account signed in: remove the device at account.microsoft.com/devices after the reset (Find my device)"
}
$bl = Get-CimInstance -Namespace "root\cimv2\Security\MicrosoftVolumeEncryption" -ClassName Win32_EncryptableVolume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $env:SystemDrive }
if ($bl) {
  $rows.Add((Row "BitLocker on $($env:SystemDrive)" $(if ($bl.ProtectionStatus -eq 1) { "on (reset with 'Clean the drive' is safe)" } else { "off" })))
} else {
  $rows.Add((Row "BitLocker" "unknown (run as admin to check)"))
}
$rows.Add((Row "Before reset" "Back up your files; sign out of OneDrive, browsers, Steam/Adobe etc. (frees licenses)" "move first"))
foreach ($b in $blockers) { $rows.Add((Row "Before selling" $b "check")) }

$rows | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host

$html = Join-Path $ReportsDir "thispc-$stamp.html"
$head = "<style>body{font-family:Segoe UI,Arial,sans-serif;margin:32px;color:#111827}table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid #e5e7eb;padding:10px 12px;text-align:left}th{background:#f9fafb}</style>"
$rows | ConvertTo-Html -Title "This PC sell report" -Head $head -PreContent "<h1>$($cs.Manufacturer) $($cs.Model)</h1><p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p>" | Set-Content -LiteralPath $html -Encoding UTF8
Write-Host "Report saved: $html"
if (-not $NoOpenReport) { Start-Process $html }

if ($Wipe) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    Write-Host "-Wipe needs an elevated prompt: right-click thispc.cmd > Run as administrator." -ForegroundColor Yellow
    exit 1
  }
  $serialText = [string]$bios.SerialNumber
  $last4 = $serialText.Substring([math]::Max(0, $serialText.Length - 4))
  Write-Host ""
  Write-Host "UNATTENDED WIPE of $($cs.Manufacturer) $($cs.Model) (serial $serialText)" -ForegroundColor Red
  Write-Host "Windows reinstalls itself and overwrites the drive. All files, apps and accounts on THIS PC are lost."
  Write-Host "It starts immediately, takes 30-90 minutes, and cannot be cancelled. Keep the charger plugged in."
  Write-Host "Afterwards: remove the laptop at account.microsoft.com/devices if it was linked to your Microsoft account."
  $answer = Read-Host "Type WIPE $last4 to start (anything else cancels)"
  if ($answer -cne "WIPE $last4") { Write-Host "Cancelled."; exit 0 }

  # The MDM bridge only accepts calls from SYSTEM, so run the call from a one-shot SYSTEM task.
  $worker = Join-Path $env:ProgramData "sellprep-wipe.ps1"
  @'
$ns = "root\cimv2\mdm\dmmap"
$session = New-CimSession
$params = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
$params.Add([Microsoft.Management.Infrastructure.CimMethodParameter]::Create("param", "", "String", "In"))
$instance = Get-CimInstance -Namespace $ns -ClassName "MDM_RemoteWipe" -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'"
# doWipeProtectedMethod = remove everything + clean drive, and keeps going after a power loss.
$session.InvokeMethod($ns, $instance, "doWipeProtectedMethod", $params) | Out-String | Set-Content "$env:ProgramData\sellprep-wipe.log"
'@ | Set-Content -LiteralPath $worker -Encoding UTF8
  $taskName = "SellPrepWipe"
  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$worker`""
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName
  Start-Sleep -Seconds 15
  $log = Get-Content "$env:ProgramData\sellprep-wipe.log" -Raw -ErrorAction SilentlyContinue
  Write-Host "Wipe requested. Windows restarts into the reset shortly."
  if ($log) { Write-Host $log }
  Write-Host "If nothing happens within 5 minutes, this Windows edition blocks MDM wipe: use thispc.cmd -Reset instead."
  exit 0
}

if ($Reset) {
  Write-Host ""
  Write-Host "Opening Windows 'Reset this PC'. Choose: Remove everything > Local reinstall > Change settings > Clean data = Yes." -ForegroundColor Cyan
  Write-Host "Nothing is erased until you confirm in that dialog."
  $answer = Read-Host "Type RESET to open it (anything else cancels)"
  if ($answer -ceq "RESET") { Start-Process "systemreset.exe" -ArgumentList "-factoryreset" } else { Write-Host "Cancelled." }
}
