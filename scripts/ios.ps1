# iPhone / iPad support through pymobiledevice3 (https://github.com/doronz88/pymobiledevice3, GPL-3.0).
# Dot-sourced by audit.ps1. Needs Apple's USB driver (usbmuxd), which ships with the
# "Apple Devices" app from the Microsoft Store (or iTunes).

$script:Pmd3Dir = Join-Path $ToolsDir "pmd3"
$script:Pmd3 = Join-Path $script:Pmd3Dir "Scripts\pymobiledevice3.exe"

function Ensure-Pmd3 {
  if (Test-Path -LiteralPath $script:Pmd3) { return $true }
  if ($SkipDownloads) {
    Write-Step "pymobiledevice3 is not installed and downloads are skipped."
    return $false
  }
  $py = Get-Command py.exe -ErrorAction SilentlyContinue
  $pyArgs = @("-3")
  if (-not $py) { $py = Get-Command python.exe -ErrorAction SilentlyContinue; $pyArgs = @() }
  if (-not $py) {
    Write-Step "Python 3 is needed for iPhone support: winget install Python.Python.3.12"
    return $false
  }
  Write-Step "Installing pymobiledevice3 into tools\pmd3 (one time)..."
  & $py.Source @pyArgs -m venv $script:Pmd3Dir 2>&1 | Out-Null
  & (Join-Path $script:Pmd3Dir "Scripts\python.exe") -m pip install -q --disable-pip-version-check pymobiledevice3 2>&1 | Add-Content -LiteralPath $LogPath
  return (Test-Path -LiteralPath $script:Pmd3)
}

function Invoke-Pmd3 {
  param([string[]]$PmdArgs, [int]$TimeoutSeconds = 60)
  $env:NO_COLOR = "1"
  $env:PYTHONIOENCODING = "utf-8"
  Add-Content -LiteralPath $LogPath -Value ("> pymobiledevice3 " + ($PmdArgs -join " "))
  $out = & $script:Pmd3 @PmdArgs 2>&1
  $text = ($out | ForEach-Object { $_.ToString() }) -join "`n"
  if ($text) { Add-Content -LiteralPath $LogPath -Value $text }
  return [pscustomobject]@{ Text = $text; Exit = $LASTEXITCODE }
}

function ConvertFrom-Pmd3Json {
  param([string]$Text)
  $start = $Text.IndexOfAny([char[]]"{[")
  if ($start -lt 0) { return $null }
  try { return ($Text.Substring($start) | ConvertFrom-Json) } catch { return $null }
}

function Test-AppleUsbDriver {
  $r = Invoke-Pmd3 -PmdArgs @("usbmux", "list", "--simple")
  if ($r.Text -match "usbmuxd") {
    Write-Step "Apple's USB driver is missing, so iPhones are invisible to Windows."
    Write-Host "  Install 'Apple Devices' from the Microsoft Store (free, by Apple), then run again." -ForegroundColor Yellow
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
      $answer = Read-Host "  Install it now with winget? You will be asked to accept the Store/Apple terms (y/N)"
      if ($answer -match "^(y|j)") {
        winget install --id 9NP83LWLPZ9K --source msstore
        Write-Host "  Unplug and replug the iPhone, tap Trust, then run sellprep.cmd again."
      }
    }
    return $false
  }
  return $true
}

function Get-IosUdids {
  $r = Invoke-Pmd3 -PmdArgs @("usbmux", "list", "--simple", "--usb")
  $list = ConvertFrom-Pmd3Json $r.Text
  $udids = @()
  foreach ($item in @($list)) {
    if ($item -is [string]) { $udids += $item }
    elseif ($item.UniqueDeviceID) { $udids += $item.UniqueDeviceID }
    elseif ($item.Identifier) { $udids += $item.Identifier }
  }
  if ($Device) { $udids = $udids | Where-Object { $_ -eq $Device } }
  return @($udids | Select-Object -Unique)
}

function Find-JsonValue {
  param($Obj, [string]$Name)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Management.Automation.PSCustomObject]) {
    $p = $Obj.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value -and -not ($p.Value -is [System.Management.Automation.PSCustomObject])) { return $p.Value }
    foreach ($child in $Obj.PSObject.Properties) {
      $v = Find-JsonValue -Obj $child.Value -Name $Name
      if ($null -ne $v) { return $v }
    }
  } elseif ($Obj -is [System.Array]) {
    foreach ($child in $Obj) {
      $v = Find-JsonValue -Obj $child -Name $Name
      if ($null -ne $v) { return $v }
    }
  }
  return $null
}

function Collect-IosInfo {
  param([string]$Udid)

  $info = ConvertFrom-Pmd3Json (Invoke-Pmd3 -PmdArgs @("lockdown", "info", "--udid", $Udid)).Text
  if (-not $info) {
    Write-Step "iPhone ${Udid}: no answer. Unlock it and tap 'Trust This Computer', then run again."
  }
  $bat = ConvertFrom-Pmd3Json (Invoke-Pmd3 -PmdArgs @("diagnostics", "battery", "single", "--udid", $Udid)).Text

  $design = Convert-ToNumber ([string](Find-JsonValue $bat "DesignCapacity"))
  $nominal = Convert-ToNumber ([string](Find-JsonValue $bat "NominalChargeCapacity"))
  $rawMax = Convert-ToNumber ([string](Find-JsonValue $bat "AppleRawMaxCapacity"))
  $cycles = Find-JsonValue $bat "CycleCount"
  $full = if ($nominal) { $nominal } else { $rawMax }
  $health = $null
  if ($full -and $design -and $design -gt 0) { $health = [math]::Round([math]::Min(100.0, $full / $design * 100.0), 1) }

  $temp = Convert-ToNumber ([string](Find-JsonValue $bat "Temperature"))
  $level = Find-JsonValue $bat "CurrentCapacity"
  if (-not $level) { $level = Find-JsonValue $bat "StateOfCharge" }

  # Find My: lockdown exposes it in the com.apple.fmip domain on most iOS versions.
  $fmip = (Invoke-Pmd3 -PmdArgs @("lockdown", "get", "--udid", $Udid, "com.apple.fmip", "IsAssociated")).Text
  $findMy = if ($fmip -match "(?i)\btrue\b") { "on" } elseif ($fmip -match "(?i)\bfalse\b") { "off" } else { "unknown" }

  $used = $null
  $disk = ConvertFrom-Pmd3Json (Invoke-Pmd3 -PmdArgs @("lockdown", "get", "--udid", $Udid, "com.apple.disk_usage")).Text
  if ($disk -and $disk.TotalDataCapacity) {
    $used = "{0:N0} GB of {1:N0} GB used" -f (($disk.TotalDataCapacity - $disk.TotalDataAvailable) / 1GB), ($disk.TotalDiskCapacity / 1GB)
  }

  $row = [pscustomobject]@{
    timestamp = (Get-Date).ToString("s")
    platform = "iOS"
    serial = $(if ($info.SerialNumber) { $info.SerialNumber } else { $Udid })
    udid = $Udid
    manufacturer = "Apple"
    brand = "Apple"
    model = "$($info.DeviceName) ($($info.ProductType))"
    android = "iOS $($info.ProductVersion)"
    sdk = $null
    level_percent = $level
    status = $null
    health_text = $null
    voltage_mv = (Find-JsonValue $bat "Voltage")
    temperature_c = $(if ($temp) { [math]::Round($temp / 100.0, 1) } else { $null })
    charge_counter_mah = $null
    estimated_full_from_charge_counter_mah = $null
    cycle_count = $cycles
    cycle_source = "AppleSmartBattery CycleCount"
    samsung_cycle_estimate = $null
    samsung_discharge_level = $null
    full_capacity_mah = $full
    full_capacity_source = $(if ($nominal) { "NominalChargeCapacity" } elseif ($rawMax) { "AppleRawMaxCapacity" } else { $null })
    design_capacity_mah = $design
    design_capacity_source = "DesignCapacity"
    health_percent_sysfs = $null
    health_percent_from_capacity = $health
    samsung_asoc_percent = $null
    samsung_bsoh_percent = $null
    samsung_first_use_date = $null
    samsung_qr_data = $null
    confidence = $(if ($health) { "high" } elseif ($bat) { "partial" } else { "unknown" })
  }
  $check = [pscustomobject]@{
    market_name    = $info.DeviceName
    security_patch = $null
    bootloader     = $null
    storage        = $used
    sim_state      = $(if ($info.SIMStatus) { $info.SIMStatus } else { $null })
    accounts_total = $null
    ready_to_reset = ($findMy -eq "off")
    reset_blockers = $(if ($findMy -eq "on") { "Find My is ON: iPhone Settings > [your name] > Find My > Find My iPhone > off (Apple ID password)" } elseif ($findMy -eq "unknown") { "Find My status unknown: turn it off in Settings > [your name] > Find My before erasing" } else { "" })
    move_first     = "Authenticator apps, banking/TAN apps, WhatsApp chats (iCloud backup), Apple Wallet cards, SIM card"
  }
  Add-SellCheck -Row $row -Check $check
  return $row
}

function Backup-IosPmd3 {
  param([string]$Udid, [string]$Label)
  $base = if ($BackupDir) { $BackupDir } else { Join-Path $Root "backups" }
  $dest = Join-Path $base (("{0}_{1}" -f ($Label -replace "[^\w\-]+", "_").Trim("_"), $Udid))
  $null = New-Item -ItemType Directory -Force -Path $dest
  Write-Step "Full iPhone backup to $dest (keep it unlocked and plugged in; this can take a while)..."
  $r = Invoke-Pmd3 -PmdArgs @("backup2", "backup", "--full", "--udid", $Udid, $dest)
  $ok = ($r.Exit -eq 0) -and (Get-ChildItem -LiteralPath $dest -Recurse -Filter "Manifest.db" -ErrorAction SilentlyContinue)
  Write-Step $(if ($ok) { "iPhone backup finished: $dest" } else { "iPhone backup did NOT finish. See log: $LogPath" })
  return [pscustomobject]@{ Path = $dest; Verified = [bool]$ok }
}

function Invoke-IosErase {
  param([string]$Udid, $Row)
  Write-Host ""
  if ($Row.ready_to_reset -ne $true) {
    Write-Step "Not erasing ${Udid}: $($Row.reset_blockers)"
    Write-Host "  Erasing with Find My on leaves Activation Lock: the buyer cannot set the iPhone up." -ForegroundColor Yellow
    return
  }
  if ($Backup -and $Row.backup_verified -ne $true) {
    Write-Step "Not erasing ${Udid}: the backup did not finish."
    return
  }
  Write-Host "  Before you continue, make sure these are moved: $($Row.move_first)" -ForegroundColor Yellow
  $last4 = $Row.serial.Substring([math]::Max(0, $Row.serial.Length - 4))
  Write-Host "  $($Row.model) (serial $($Row.serial)) will be ERASED to factory state now." -ForegroundColor Cyan
  $answer = Read-Host "  Type ERASE $last4 to erase it (anything else cancels)"
  if ($answer -cne "ERASE $last4") {
    Write-Step "Erase cancelled for $Udid."
    return
  }
  $tmp = Join-Path $env:TEMP ("pmd3-erase-" + [guid]::NewGuid().ToString("N"))
  $null = New-Item -ItemType Directory -Force -Path $tmp
  Write-Step "Erasing $Udid ..."
  $r = Invoke-Pmd3 -PmdArgs @("backup2", "erase-device", "--udid", $Udid, $tmp)
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  if ($r.Exit -eq 0) {
    Write-Step "Erase started. The iPhone shows the Apple logo and a progress bar, then the Hello screen."
  } else {
    Write-Step "Erase was refused by the iPhone. Use Settings > General > Transfer or Reset > Erase All Content and Settings."
    Write-Host "  $($r.Text)"
  }
}
