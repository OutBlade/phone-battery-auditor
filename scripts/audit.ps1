param(
  [switch]$NoInstall,
  [switch]$SkipDownloads,
  [switch]$SetupApps,
  [switch]$LaunchApp,
  [switch]$ForceInstall,
  [switch]$InstallBatt,
  [switch]$ReadScreen,
  [ValidateSet("auto", "batt", "abattery")]
  [string]$OpenApp = "auto",
  [string]$Device,
  [switch]$ListOnly,
  [switch]$NoOpenReport,
  [switch]$Help
)

$ErrorActionPreference = "Continue"
$PSNativeCommandUseErrorActionPreference = $false
$ProgressPreference = "SilentlyContinue"

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ToolsDir = Join-Path $Root "tools"
$DownloadsDir = Join-Path $Root "downloads"
$ApksDir = Join-Path $Root "apks"
$ReportsDir = Join-Path $Root "reports"
$LogsDir = Join-Path $Root "logs"
$null = New-Item -ItemType Directory -Force -Path $ToolsDir, $DownloadsDir, $ApksDir, $ReportsDir, $LogsDir

$ReportStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportPath = Join-Path $ReportsDir "battery-audit-$ReportStamp.csv"
$LogPath = Join-Path $LogsDir "battery-audit-$ReportStamp.log"
$Rows = New-Object System.Collections.Generic.List[object]

if ($Help) {
  Write-Host @"
Android Battery Auditor

Usage:
  run.cmd                  Run pure ADB audit and open an HTML report
  run.cmd -ListOnly        Show connected ADB devices only
  run.cmd -Device SERIAL   Audit one selected device
  run.cmd -NoOpenReport    Save reports without opening the HTML report

Optional app setup:
  run.cmd -SetupApps       Install/use Shizuku and optional apks\abattery.apk
  run.cmd -InstallBatt     Also install Batt
  run.cmd -LaunchApp       Open aBattery/Batt after the report

Required on the phone:
  Developer options -> USB debugging -> Allow USB debugging prompt
"@
  exit 0
}

function Write-Step {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message
  Write-Host $line
  Add-Content -LiteralPath $LogPath -Value $line
}

function Find-Adb {
  $localAdb = Join-Path $ToolsDir "platform-tools\adb.exe"
  if (Test-Path -LiteralPath $localAdb) {
    return $localAdb
  }

  $pathAdb = Get-Command adb.exe -ErrorAction SilentlyContinue
  if ($pathAdb) {
    return $pathAdb.Source
  }

  return $null
}

function Ensure-Adb {
  $adb = Find-Adb
  if ($adb) {
    return $adb
  }

  if ($SkipDownloads) {
    throw "adb.exe was not found. Put platform-tools in tools\platform-tools or remove -SkipDownloads."
  }

  Write-Step "Downloading Google Android SDK Platform Tools..."
  $zipPath = Join-Path $DownloadsDir "platform-tools-latest-windows.zip"
  Invoke-WebRequest -Uri "https://dl.google.com/android/repository/platform-tools-latest-windows.zip" -OutFile $zipPath
  Expand-Archive -Path $zipPath -DestinationPath $ToolsDir -Force

  $adb = Find-Adb
  if (-not $adb) {
    throw "Downloaded platform-tools, but adb.exe was not found."
  }

  return $adb
}

function Download-FileIfMissing {
  param(
    [string]$Uri,
    [string]$Path,
    [string]$Name
  )

  if (Test-Path -LiteralPath $Path) {
    return
  }

  if ($SkipDownloads) {
    Write-Step "$Name is missing, downloads are skipped: $Path"
    return
  }

  Write-Step "Downloading $Name..."
  Invoke-WebRequest -Uri $Uri -OutFile $Path
}

function Ensure-Apks {
  $shizukuPath = Join-Path $ApksDir "shizuku.apk"
  $battPath = Join-Path $ApksDir "batt.apk"

  if (-not (Test-Path -LiteralPath $shizukuPath) -and -not $SkipDownloads) {
    Write-Step "Resolving latest Shizuku APK from GitHub..."
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/RikkaApps/Shizuku/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -like "*.apk" } | Select-Object -First 1
    if (-not $asset) {
      throw "Could not find Shizuku APK asset in the latest GitHub release."
    }
    Download-FileIfMissing -Uri $asset.browser_download_url -Path $shizukuPath -Name "Shizuku $($release.tag_name)"
  }

  if ($InstallBatt -and -not (Test-Path -LiteralPath $battPath) -and -not $SkipDownloads) {
    Write-Step "Resolving latest Batt APK from GitLab..."
    $releases = Invoke-RestMethod -Uri "https://gitlab.com/api/v4/projects/narektor%2Fbatt/releases"
    $latest = $releases | Select-Object -First 1
    $asset = $latest.assets.links | Where-Object { $_.name -eq "APK" -or $_.direct_asset_url -like "*.apk" -or $_.url -like "*.apk" } | Select-Object -First 1
    if (-not $asset) {
      throw "Could not find Batt APK asset in GitLab releases."
    }
    $url = if ($asset.direct_asset_url) { $asset.direct_asset_url } else { $asset.url }
    Download-FileIfMissing -Uri $url -Path $battPath -Name "Batt $($latest.tag_name)"
  }

  return @{
    Shizuku = $shizukuPath
    Batt = $battPath
    ABattery = Join-Path $ApksDir "abattery.apk"
  }
}

function Invoke-Adb {
  param(
    [string[]]$AdbArgs,
    [switch]$AllowFail
  )

  $output = & $script:Adb @AdbArgs 2>&1
  $exit = $LASTEXITCODE
  $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
  Add-Content -LiteralPath $LogPath -Value ("> adb " + ($AdbArgs -join " "))
  if ($text) {
    Add-Content -LiteralPath $LogPath -Value $text
  }
  if ($exit -ne 0 -and -not $AllowFail) {
    throw "adb failed ($exit): adb $($AdbArgs -join ' ')`n$text"
  }
  return $text.Trim()
}

function Invoke-DeviceAdb {
  param(
    [string]$Serial,
    [string[]]$AdbArgs,
    [switch]$AllowFail
  )
  return Invoke-Adb -AdbArgs (@("-s", $Serial) + $AdbArgs) -AllowFail:$AllowFail
}

function Quote-Arg {
  param([string]$Value)
  if ($Value -notmatch '[\s"]') {
    return $Value
  }
  return '"' + ($Value -replace '\\(?=\\*")', '$0\' -replace '"', '\"') + '"'
}

function Invoke-DeviceAdbWithTimeout {
  param(
    [string]$Serial,
    [string[]]$AdbArgs,
    [int]$TimeoutSeconds = 120
  )

  $allArgs = @("-s", $Serial) + $AdbArgs
  $argLine = ($allArgs | ForEach-Object { Quote-Arg $_ }) -join " "
  $stdoutPath = Join-Path $LogsDir ("adb-stdout-{0}.txt" -f ([guid]::NewGuid().ToString("N")))
  $stderrPath = Join-Path $LogsDir ("adb-stderr-{0}.txt" -f ([guid]::NewGuid().ToString("N")))
  Add-Content -LiteralPath $LogPath -Value ("> adb " + ($allArgs -join " "))

  $process = Start-Process -FilePath $script:Adb -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    try {
      $process.Kill()
    } catch {
      # Process may have exited between timeout detection and kill.
    }
    $text = "Timed out after ${TimeoutSeconds}s: adb $($allArgs -join ' ')"
    Add-Content -LiteralPath $LogPath -Value $text
    return $text
  }

  $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { "" }
  $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { "" }
  Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  $text = (($stdout, $stderr) | Where-Object { $_ }) -join "`n"
  if ($text) {
    Add-Content -LiteralPath $LogPath -Value $text.Trim()
  }
  return $text.Trim()
}

function Get-Devices {
  Invoke-Adb -AdbArgs @("start-server") | Out-Null
  $raw = Invoke-Adb -AdbArgs @("devices", "-l")
  $devices = @()
  foreach ($line in ($raw -split "`r?`n")) {
    if ($line -match "^\s*$" -or $line -like "List of devices*") {
      continue
    }
    if ($line -match "^(?<serial>\S+)\s+(?<state>\S+)(?<rest>.*)$") {
      $devices += [pscustomobject]@{
        Serial = $Matches.serial
        State = $Matches.state
        Details = $Matches.rest.Trim()
      }
    }
  }
  if ($Device) {
    $devices = $devices | Where-Object { $_.Serial -eq $Device }
  }
  return @($devices)
}

function Get-Prop {
  param([string]$Serial, [string]$Name)
  return (Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "getprop", $Name) -AllowFail).Trim()
}

function Parse-DumpsysBattery {
  param([string]$Text)
  $map = @{}
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match "^\s*([^:]+):\s*(.*)$") {
      $key = ($Matches[1].Trim() -replace "\s+", "_").ToLowerInvariant()
      $map[$key] = $Matches[2].Trim()
    }
  }
  return $map
}

function Get-RegexValue {
  param(
    [string]$Text,
    [string]$Pattern
  )
  $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($match.Success -and $match.Groups.Count -gt 1) {
    return $match.Groups[1].Value.Trim()
  }
  return $null
}

function Convert-ToMah {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) {
    return $null
  }
  $clean = ($Raw -replace "[^0-9\.-]", "")
  if (-not $clean) {
    return $null
  }
  $value = 0.0
  if (-not [double]::TryParse($clean, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
    return $null
  }
  if ($value -eq 0) {
    return $null
  }
  if ([math]::Abs($value) -gt 100000) {
    return [math]::Round($value / 1000, 1)
  }
  return [math]::Round($value, 1)
}

function Convert-ToNumber {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) {
    return $null
  }
  $clean = ($Raw -replace "[^0-9\.-]", "")
  if (-not $clean) {
    return $null
  }
  $value = 0.0
  if ([double]::TryParse($clean, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
    return $value
  }
  return $null
}

function Read-SysfsFirst {
  param(
    [string]$Serial,
    [string[]]$Paths
  )

  foreach ($path in $Paths) {
    $cmd = "if [ -r '$path' ]; then cat '$path'; fi"
    $value = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", $cmd) -AllowFail
    if ([string]::IsNullOrWhiteSpace($value)) {
      continue
    }
    $firstLine = $value -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($firstLine)) {
      continue
    }
    $value = $firstLine.Trim()
    if ($value) {
      return [pscustomobject]@{ Path = $path; Value = $value }
    }
  }
  return $null
}

function Install-Apk {
  param(
    [string]$Serial,
    [string]$Path,
    [string]$Name,
    [string]$Package
  )
  if (-not (Test-Path -LiteralPath $Path)) {
    Write-Step "$Name APK not found, skipping: $Path"
    return $false
  }

  if ($Package -and -not $ForceInstall -and (Package-Installed -Serial $Serial -Package $Package)) {
    Write-Step "$Name is already installed on $Serial, skipping install. Use -ForceInstall to reinstall."
    return $true
  }

  Write-Step "Installing $Name on $Serial..."
  $result = Invoke-DeviceAdbWithTimeout -Serial $Serial -AdbArgs @("install", "--no-streaming", "-r", "-d", $Path) -TimeoutSeconds 120
  if ($result -match "Success") {
    return $true
  }
  if ($result -match "INSTALL_FAILED_VERSION_DOWNGRADE") {
    Write-Step "$Name install skipped: newer version is already installed."
    return $true
  }
  Write-Step "$Name install output: $result"
  return $false
}

function Package-Installed {
  param([string]$Serial, [string]$Package)
  $out = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "pm", "path", $Package) -AllowFail
  return $out -match "^package:"
}

function Grant-AppPermission {
  param(
    [string]$Serial,
    [string]$Package,
    [string]$Permission
  )
  if (-not (Package-Installed -Serial $Serial -Package $Package)) {
    return $false
  }
  Write-Step "Granting $Permission to $Package on $Serial..."
  $out = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "pm", "grant", $Package, $Permission) -AllowFail
  if ($out -match "Exception|SecurityException|Unknown package") {
    Write-Step "Grant failed for ${Package} / ${Permission}: $out"
    return $false
  }
  return $true
}

function Grant-BatteryAppPermissions {
  param([string]$Serial, [string]$Package)
  Grant-AppPermission -Serial $Serial -Package $Package -Permission "android.permission.BATTERY_STATS" | Out-Null
  Grant-AppPermission -Serial $Serial -Package $Package -Permission "moe.shizuku.manager.permission.API_V23" | Out-Null
}

function Launch-Package {
  param([string]$Serial, [string]$Package)
  if (-not (Package-Installed -Serial $Serial -Package $Package)) {
    return $false
  }
  Write-Step "Opening $Package on $Serial..."
  $resolveCommand = "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $Package 2>/dev/null | tail -n 1"
  $component = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", $resolveCommand) -AllowFail
  $component = ($component -split "`r?`n" | Where-Object { $_ -match "/" } | Select-Object -Last 1).Trim()

  if ($component) {
    $out = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "am", "start", "-n", $component) -AllowFail
    if ($out -notmatch "Error|Exception") {
      return $true
    }
    Write-Step "am start failed for ${Package}: $out"
  }

  Write-Step "Could not resolve launcher activity for $Package."
  return $false
}

function Force-StopPackage {
  param([string]$Serial, [string]$Package)
  if (-not (Package-Installed -Serial $Serial -Package $Package)) {
    return
  }
  Write-Step "Force-stopping $Package on $Serial..."
  Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "am", "force-stop", $Package) -AllowFail | Out-Null
}

function Get-ForegroundUiText {
  param([string]$Serial)
  $dump = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "uiautomator", "dump", "/sdcard/android-battery-auditor-window.xml") -AllowFail
  if ($dump -match "ERROR|Exception|Killed|not found") {
    return @()
  }
  $xml = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "cat", "/sdcard/android-battery-auditor-window.xml") -AllowFail
  if ([string]::IsNullOrWhiteSpace($xml)) {
    return @()
  }
  $texts = New-Object System.Collections.Generic.List[string]
  foreach ($match in [regex]::Matches($xml, 'text="([^"]+)"')) {
    $text = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value).Trim()
    if ($text -and -not $texts.Contains($text)) {
      $texts.Add($text)
    }
  }
  return @($texts)
}

function Print-AppScreenText {
  param(
    [string]$Serial,
    [string]$Package
  )
  if (-not (Launch-Package -Serial $Serial -Package $Package)) {
    return
  }
  Start-Sleep -Seconds 3
  $texts = Get-ForegroundUiText -Serial $Serial
  if ($texts.Count -eq 0) {
    Write-Step "Could not read visible text from $Package. Unlock the screen if the app is not visible."
    return
  }
  Write-Host ""
  Write-Host "Visible app text:"
  $texts | Select-Object -First 40 | ForEach-Object { Write-Host ("  " + $_) }
}

function Start-Shizuku {
  param([string]$Serial)
  if (-not (Package-Installed -Serial $Serial -Package "moe.shizuku.privileged.api")) {
    Write-Step "Shizuku is not installed on $Serial."
    return $false
  }

  Write-Step "Starting Shizuku via USB ADB on $Serial..."
  $startCommand = @'
APK=$(pm path moe.shizuku.privileged.api | head -1 | cut -d: -f2)
DIR=${APK%base.apk}
if [ -x "${DIR}lib/arm64/libshizuku.so" ]; then
  "${DIR}lib/arm64/libshizuku.so"
elif [ -x "${DIR}lib/arm/libshizuku.so" ]; then
  "${DIR}lib/arm/libshizuku.so"
elif [ -r "/storage/emulated/0/Android/data/moe.shizuku.privileged.api/start.sh" ]; then
  sh "/storage/emulated/0/Android/data/moe.shizuku.privileged.api/start.sh"
elif [ -r "/sdcard/Android/data/moe.shizuku.privileged.api/start.sh" ]; then
  sh "/sdcard/Android/data/moe.shizuku.privileged.api/start.sh"
else
  echo "No Shizuku starter found"
  exit 1
fi
'@
  $out = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", $startCommand) -AllowFail
  if ($out -match "exit with 0|shizuku_server pid|starting server|starter begin") {
    Write-Step "Shizuku start output: $out"
    return $true
  }
  Write-Step "Shizuku start output: $out"
  return $false
}

function Collect-BatteryInfo {
  param([string]$Serial)

  $manufacturer = Get-Prop -Serial $Serial -Name "ro.product.manufacturer"
  $brand = Get-Prop -Serial $Serial -Name "ro.product.brand"
  $model = Get-Prop -Serial $Serial -Name "ro.product.model"
  $android = Get-Prop -Serial $Serial -Name "ro.build.version.release"
  $sdk = Get-Prop -Serial $Serial -Name "ro.build.version.sdk"

  $dumpsys = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "dumpsys", "battery") -AllowFail
  $battery = Parse-DumpsysBattery -Text $dumpsys

  $cycle = Read-SysfsFirst -Serial $Serial -Paths @(
    "/sys/class/power_supply/battery/cycle_count",
    "/sys/class/power_supply/battery/battery_cycle",
    "/sys/class/power_supply/battery/cycle",
    "/sys/class/power_supply/battery/fg_cycle",
    "/sys/class/power_supply/battery/batt_cycle",
    "/sys/class/power_supply/bms/cycle_count",
    "/sys/class/qcom-battery/battery/cycle_count",
    "/sys/class/oplus_chg/battery/cycle_count",
    "/sys/class/oplus_chg/battery/battery_cycle",
    "/sys/class/oplus_chg/battery/chg_cycle",
    "/sys/class/oplus_chg/battery/batt_cycle_count"
  )

  $full = Read-SysfsFirst -Serial $Serial -Paths @(
    "/sys/class/power_supply/battery/charge_full",
    "/sys/class/power_supply/battery/energy_full",
    "/sys/class/power_supply/battery/batt_full_capacity",
    "/sys/class/power_supply/battery/battery_full_capacity",
    "/sys/class/power_supply/battery/fg_fullcapnom",
    "/sys/class/power_supply/battery/full_capacity",
    "/sys/class/power_supply/bms/charge_full",
    "/sys/class/qcom-battery/battery/charge_full",
    "/sys/class/qcom-battery/battery/charge_full_rep",
    "/sys/class/oplus_chg/battery/battery_fcc",
    "/sys/class/oplus_chg/battery/batt_fcc",
    "/sys/class/oplus_chg/battery/fcc",
    "/sys/class/oplus_chg/battery/qmax"
  )

  $design = Read-SysfsFirst -Serial $Serial -Paths @(
    "/sys/class/power_supply/battery/charge_full_design",
    "/sys/class/power_supply/battery/energy_full_design",
    "/sys/class/power_supply/battery/batt_full_capacity_design",
    "/sys/class/power_supply/battery/battery_full_capacity_design",
    "/sys/class/power_supply/battery/design_capacity",
    "/sys/class/power_supply/bms/charge_full_design",
    "/sys/class/qcom-battery/battery/charge_full_design",
    "/sys/class/oplus_chg/battery/charge_full_design",
    "/sys/class/oplus_chg/battery/design_capacity"
  )

  $healthPercent = Read-SysfsFirst -Serial $Serial -Paths @(
    "/sys/class/power_supply/battery/batt_asoc",
    "/sys/class/power_supply/battery/battery_asoc",
    "/sys/class/power_supply/battery/asoc",
    "/sys/class/power_supply/battery/soh",
    "/sys/class/power_supply/battery/battery_soh",
    "/sys/class/power_supply/battery/bsoh",
    "/sys/class/power_supply/battery/fg_asoc",
    "/sys/class/qcom-battery/battery/soh",
    "/sys/class/qcom-battery/battery/battery_soh",
    "/sys/class/oplus_chg/battery/battery_soh",
    "/sys/class/oplus_chg/battery/soh",
    "/sys/class/oplus_chg/battery/batt_soh"
  )

  $dumpsysCycle = Get-RegexValue -Text $dumpsys -Pattern "(?:^|[\s,])cycle[_ ]count:\s*([0-9]+)"
  $samsungAsoc = Get-RegexValue -Text $dumpsys -Pattern "mSavedBatteryAsoc:\s*\[?([0-9]+)\]?"
  $samsungUsage = Get-RegexValue -Text $dumpsys -Pattern "mSavedBatteryUsage:\s*\[?([0-9]+)\]?"
  $samsungBsoh = Get-RegexValue -Text $dumpsys -Pattern "mSavedBatteryBsoh:\s*([0-9]+)"
  $samsungFirstUse = Get-RegexValue -Text $dumpsys -Pattern "battery FirstUseDate:\s*\[?([0-9]{8})\]?"
  if (-not $samsungFirstUse) {
    $samsungFirstUse = Get-RegexValue -Text $dumpsys -Pattern "FirstUseDateData efsValue:\s*([0-9]{8})"
  }
  $samsungQrData = Get-RegexValue -Text $dumpsys -Pattern "QrData efsValue:\s*([^`r`n]+)"
  $samsungCycleEstimate = $null
  if ($samsungUsage) {
    $usageNumber = Convert-ToNumber $samsungUsage
    if ($usageNumber -ne $null) {
      $samsungCycleEstimate = [math]::Round($usageNumber / 100.0, 2)
    }
  }

  $level = Convert-ToNumber $battery["level"]
  $chargeCounterMah = Convert-ToMah $battery["charge_counter"]
  $estimatedFullMah = $null
  if ($chargeCounterMah -and $level -and $level -gt 0) {
    $estimatedFullMah = [math]::Round($chargeCounterMah / ($level / 100.0), 1)
  }

  $fullMah = Convert-ToMah $(if ($full) { $full.Value } else { $null })
  $designMah = Convert-ToMah $(if ($design) { $design.Value } else { $null })
  $healthFromCapacity = $null
  if ($fullMah -and $designMah -and $designMah -gt 0) {
    $healthFromCapacity = [math]::Round(($fullMah / $designMah) * 100.0, 1)
  }

  return [pscustomobject]@{
    timestamp = (Get-Date).ToString("s")
    serial = $Serial
    manufacturer = $manufacturer
    brand = $brand
    model = $model
    android = $android
    sdk = $sdk
    level_percent = $battery["level"]
    status = $battery["status"]
    health_text = $battery["health"]
    voltage_mv = $battery["voltage"]
    temperature_c = $(if ($battery["temperature"]) { [math]::Round((Convert-ToNumber $battery["temperature"]) / 10.0, 1) } else { $null })
    charge_counter_mah = $chargeCounterMah
    estimated_full_from_charge_counter_mah = $estimatedFullMah
    cycle_count = $(if ($cycle) { $cycle.Value } elseif ($dumpsysCycle -and $dumpsysCycle -ne "0") { $dumpsysCycle } else { $null })
    cycle_source = $(if ($cycle) { $cycle.Path } elseif ($dumpsysCycle -and $dumpsysCycle -ne "0") { "dumpsys battery cycle_count" } else { $null })
    samsung_cycle_estimate = $samsungCycleEstimate
    samsung_discharge_level = $samsungUsage
    full_capacity_mah = $fullMah
    full_capacity_source = $(if ($full) { $full.Path } else { $null })
    design_capacity_mah = $designMah
    design_capacity_source = $(if ($design) { $design.Path } else { $null })
    health_percent_sysfs = $(if ($healthPercent) { $healthPercent.Value } else { $null })
    health_percent_from_capacity = $healthFromCapacity
    samsung_asoc_percent = $samsungAsoc
    samsung_bsoh_percent = $samsungBsoh
    samsung_first_use_date = $samsungFirstUse
    samsung_qr_data = $samsungQrData
    confidence = $(if ($samsungAsoc -or $healthPercent -or ($fullMah -and $designMah)) { "high" } elseif ($estimatedFullMah) { "estimate" } else { "unknown" })
  }
}

function Print-Result {
  param([object]$Row)
  Write-Host ""
  Write-Host ("Device: {0} {1} / Android {2} / {3}" -f $Row.manufacturer, $Row.model, $Row.android, $Row.serial)
  Write-Host ("Battery: {0}% | status={1} | health={2} | temp={3}C | voltage={4}mV" -f $Row.level_percent, $Row.status, $Row.health_text, $Row.temperature_c, $Row.voltage_mv)
  Write-Host ("Cycles: {0}" -f $(if ($Row.cycle_count) { $Row.cycle_count } elseif ($Row.samsung_cycle_estimate) { "$($Row.samsung_cycle_estimate) estimated from Samsung usage" } else { "unknown" }))
  Write-Host ("Full capacity: {0} mAh" -f $(if ($Row.full_capacity_mah) { $Row.full_capacity_mah } else { "unknown" }))
  Write-Host ("Design capacity: {0} mAh" -f $(if ($Row.design_capacity_mah) { $Row.design_capacity_mah } else { "unknown" }))
  Write-Host ("Health: sysfs={0}% capacity_calc={1}% samsung_asoc={2}% samsung_bsoh={3}%" -f $(if ($Row.health_percent_sysfs) { $Row.health_percent_sysfs } else { "unknown" }), $(if ($Row.health_percent_from_capacity) { $Row.health_percent_from_capacity } else { "unknown" }), $(if ($Row.samsung_asoc_percent) { $Row.samsung_asoc_percent } else { "unknown" }), $(if ($Row.samsung_bsoh_percent) { $Row.samsung_bsoh_percent } else { "unknown" }))
  if ($Row.samsung_asoc_percent) {
    Write-Host ("Maximum capacity: {0}%" -f $Row.samsung_asoc_percent)
  }
  if ($Row.samsung_first_use_date) {
    Write-Host ("Samsung first use date: {0}" -f $Row.samsung_first_use_date)
  }
  Write-Host ("Estimate from current charge counter: {0} mAh" -f $(if ($Row.estimated_full_from_charge_counter_mah) { $Row.estimated_full_from_charge_counter_mah } else { "unknown" }))
  Write-Host ("Confidence: {0}" -f $Row.confidence)
}

function Write-HtmlReport {
  param(
    $Rows,
    [string]$Path
  )

  $items = foreach ($row in $Rows) {
    $capacity = if ($row.samsung_asoc_percent) { "$($row.samsung_asoc_percent)%" } elseif ($row.health_percent_from_capacity) { "$($row.health_percent_from_capacity)%" } else { "unknown" }
    $cycles = if ($row.cycle_count) { $row.cycle_count } elseif ($row.samsung_cycle_estimate) { "$($row.samsung_cycle_estimate) est." } else { "unknown" }
    [pscustomobject]@{
      Serial = [string]$row.serial
      Device = [string]"$($row.manufacturer) $($row.model)"
      Android = [string]$row.android
      Battery = [string]"$($row.level_percent)%"
      "Maximum capacity" = [string]$capacity
      Cycles = [string]$cycles
      "First use" = [string]$row.samsung_first_use_date
      "Estimated full mAh" = [string]$row.estimated_full_from_charge_counter_mah
      Confidence = [string]$row.confidence
    }
  }

  $head = @"
<style>
  body { font-family: Segoe UI, Arial, sans-serif; margin: 32px; color: #111827; }
  h1 { margin-bottom: 4px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border-bottom: 1px solid #e5e7eb; padding: 10px 12px; text-align: left; }
  th { background: #f9fafb; font-weight: 600; }
</style>
"@
  $html = $items | ConvertTo-Html -Title "Android Battery Auditor Report" -Head $head -PreContent "<h1>Android Battery Auditor Report</h1><p>Generated $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>"
  Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}

Write-Step "Android Battery Auditor started."
$script:Adb = Ensure-Adb
Write-Step "Using adb: $script:Adb"

$apks = $null
if ($SetupApps -or $InstallBatt -or $LaunchApp -or $ReadScreen) {
  $apks = Ensure-Apks
} else {
  Write-Step "App setup is disabled by default. Running pure ADB battery audit."
}
$devices = @(Get-Devices)
if ($devices.Count -eq 0) {
  Write-Step "No ADB devices found. Connect a phone with USB debugging enabled."
  exit 2
}

Write-Step "Found $($devices.Count) ADB device(s)."
foreach ($dev in $devices) {
  Write-Step "Device $($dev.Serial): $($dev.State) $($dev.Details)"
}

if ($ListOnly) {
  exit 0
}

foreach ($dev in $devices) {
  if ($dev.State -ne "device") {
    Write-Step "Skipping $($dev.Serial): state is '$($dev.State)'. If it says unauthorized, tap 'Allow USB debugging' on the phone and run again."
    continue
  }

  Write-Step "Processing $($dev.Serial)..."

  if (($SetupApps -or $InstallBatt) -and -not $NoInstall) {
    Install-Apk -Serial $dev.Serial -Path $apks.Shizuku -Name "Shizuku" -Package "moe.shizuku.privileged.api" | Out-Null
    if ($InstallBatt) {
      Install-Apk -Serial $dev.Serial -Path $apks.Batt -Name "Batt" -Package "com.porg.batt" | Out-Null
    } else {
      Write-Step "Batt install is disabled by default to avoid Android old-target-SDK warnings. Use -InstallBatt if you want it."
    }
    if (Test-Path -LiteralPath $apks.ABattery) {
      Install-Apk -Serial $dev.Serial -Path $apks.ABattery -Name "aBattery" -Package "me.linshen.abattery" | Out-Null
    } elseif (Package-Installed -Serial $dev.Serial -Package "me.linshen.abattery") {
      Write-Step "aBattery is already installed on $($dev.Serial), skipping install."
    } else {
      Write-Step "Optional aBattery APK not found. Put it at apks\abattery.apk if you want to install/open aBattery."
    }

    Grant-BatteryAppPermissions -Serial $dev.Serial -Package "com.porg.batt"
    Grant-BatteryAppPermissions -Serial $dev.Serial -Package "me.linshen.abattery"
    Start-Shizuku -Serial $dev.Serial | Out-Null
    if ($LaunchApp -or $ReadScreen) {
      Force-StopPackage -Serial $dev.Serial -Package "me.linshen.abattery"
      Force-StopPackage -Serial $dev.Serial -Package "com.porg.batt"
    }
  }

  $row = Collect-BatteryInfo -Serial $dev.Serial
  $Rows.Add($row)
  Print-Result -Row $row

  if ($LaunchApp -or $ReadScreen) {
    $opened = $false
    if ($OpenApp -eq "abattery" -or $OpenApp -eq "auto") {
      if (Package-Installed -Serial $dev.Serial -Package "me.linshen.abattery") {
        if ($ReadScreen) {
          Print-AppScreenText -Serial $dev.Serial -Package "me.linshen.abattery"
        } else {
          Launch-Package -Serial $dev.Serial -Package "me.linshen.abattery" | Out-Null
        }
        $opened = $true
      }
    }
    if (-not $opened -and ($OpenApp -eq "batt" -or $OpenApp -eq "auto")) {
      if (Package-Installed -Serial $dev.Serial -Package "com.porg.batt") {
        if ($ReadScreen) {
          Print-AppScreenText -Serial $dev.Serial -Package "com.porg.batt"
        } else {
          Launch-Package -Serial $dev.Serial -Package "com.porg.batt" | Out-Null
        }
        $opened = $true
      }
    }
  }
}

if ($Rows.Count -gt 0) {
  $Rows | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding UTF8
  $HtmlReportPath = Join-Path $ReportsDir "battery-audit-$ReportStamp.html"
  Write-HtmlReport -Rows $Rows.ToArray() -Path $HtmlReportPath
  Write-Step "CSV report saved: $ReportPath"
  Write-Step "HTML report saved: $HtmlReportPath"
  if (-not $NoOpenReport) {
    Write-Step "Opening HTML report..."
    Start-Process -FilePath $HtmlReportPath
  }
} else {
  Write-Step "No authorized devices were processed."
  exit 3
}

Write-Step "Done."
