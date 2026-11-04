# Sell-prep helpers: readiness check, verified backup and guarded reset.
# Dot-sourced by audit.ps1; uses its Invoke-DeviceAdb, Get-Prop, Write-Step and $Root.
# Nothing here erases data. The reset flow only reboots into recovery after a typed
# confirmation; the wipe itself is chosen by the person on the phone.

# Accounts that trigger Factory Reset Protection (the phone stays locked after a wipe).
$script:FrpAccountTypes = [ordered]@{
  "com.google"          = "Google"
  "com.xiaomi"          = "Xiaomi (Mi)"
  "com.osp.app.signin"  = "Samsung"
  "com.huawei.hwid"     = "Huawei"
  "com.oplus.account"   = "OPPO/OnePlus"
  "com.heytap.usercenter" = "OPPO/Realme (HeyTap)"
  "com.vivo.sdkplugin"  = "vivo"
}

# Apps whose data is lost on reset and must be moved by hand first.
$script:MoveFirstApps = [ordered]@{
  "com.google.android.apps.authenticator2" = "Google Authenticator (Transfer accounts to new phone)"
  "com.azure.authenticator"                = "Microsoft Authenticator"
  "com.authy.authy"                        = "Authy"
  "com.beemdevelopment.aegis"              = "Aegis Authenticator"
  "com.twofasapp"                          = "2FAS Authenticator"
  "org.fedorahosted.freeotp"               = "FreeOTP"
  "com.starfinanz.mobile.android.pushtan"  = "S-pushTAN (re-register on new phone)"
  "de.fiducia.smartphone.android.securego" = "VR SecureGo plus"
  "com.governikus.ausweisapp2"             = "AusweisApp (set up again)"
  "com.whatsapp"                           = "WhatsApp (back up chats to Google Drive)"
  "org.telegram.messenger"                 = "Telegram (cloud-synced, just log in on new phone)"
  "com.google.android.apps.walletnfcrel"   = "Google Wallet (cards are removed on reset)"
}

function Hide-AccountName {
  param([string]$Name)
  if ($Name -match "^(.{1,2})[^@]*(@.+)$") { return "$($Matches[1])***$($Matches[2])" }
  if ($Name.Length -gt 3) { return $Name.Substring(0, 2) + "***" }
  return "***"
}

function Get-AndroidAccounts {
  param([string]$Serial)
  $text = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "dumpsys", "account") -AllowFail
  $seen = @{}
  $list = @()
  foreach ($m in [regex]::Matches($text, "Account \{name=([^,]+), type=([^}]+)\}")) {
    $key = "$($m.Groups[1].Value)|$($m.Groups[2].Value)"
    if (-not $seen.ContainsKey($key)) {
      $seen[$key] = $true
      $list += [pscustomobject]@{ Name = $m.Groups[1].Value.Trim(); Type = $m.Groups[2].Value.Trim() }
    }
  }
  return $list
}

function Get-AndroidSellCheck {
  param([string]$Serial)

  $accounts = @(Get-AndroidAccounts -Serial $Serial)
  $frp = @($accounts | Where-Object { $script:FrpAccountTypes.Contains($_.Type) })
  $blockers = @()
  foreach ($a in $frp) {
    $blockers += "Signed in: $($script:FrpAccountTypes[$a.Type]) $(Hide-AccountName $a.Name)"
  }

  $packages = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "pm", "list", "packages") -AllowFail
  $moveFirst = @()
  foreach ($pkg in $script:MoveFirstApps.Keys) {
    if ($packages -match "(?m)^package:$([regex]::Escape($pkg))\s*$") { $moveFirst += $script:MoveFirstApps[$pkg] }
  }

  $simState = Get-Prop -Serial $Serial -Name "gsm.sim.state"
  if ($simState -match "READY|LOADED") { $moveFirst += "SIM card still inserted" }

  $df = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "df -h /data | tail -1") -AllowFail
  $storage = $null
  if ($df -match "\s(\S+)\s+(\S+)\s+(\S+)\s+(\d+%)") { $storage = "$($Matches[2]) of $($Matches[1]) used ($($Matches[4]))" }

  $bootState = Get-Prop -Serial $Serial -Name "ro.boot.verifiedbootstate"
  $flashLocked = Get-Prop -Serial $Serial -Name "ro.boot.flash.locked"

  return [pscustomobject]@{
    market_name      = $(Get-Prop -Serial $Serial -Name "ro.product.marketname")
    security_patch   = $(Get-Prop -Serial $Serial -Name "ro.build.version.security_patch")
    bootloader       = $(if ($flashLocked -eq "1" -or $bootState -eq "green") { "locked" } elseif ($flashLocked -eq "0" -or $bootState -eq "orange") { "UNLOCKED" } else { "unknown" })
    storage          = $storage
    sim_state        = $simState
    accounts_total   = $accounts.Count
    ready_to_reset   = ($blockers.Count -eq 0)
    reset_blockers   = ($blockers -join "; ")
    move_first       = ($moveFirst -join "; ")
  }
}

function Get-IosSellCheck {
  param($IosTools, [string]$Udid)
  $fmip = $null
  if ($IosTools -and $IosTools.Info) {
    $fmip = Invoke-IosTool -Exe $IosTools.Info -ToolArgs @("-u", $Udid, "-q", "com.apple.fmip", "-k", "IsAssociated") -AllowFail
  }
  $blockers = @()
  if ($fmip -match "true") { $blockers += "Find My is on: Settings > [your name] > Find My > turn off (needs Apple ID password)" }
  return [pscustomobject]@{
    market_name      = $null
    security_patch   = $null
    bootloader       = $null
    storage          = $null
    sim_state        = $null
    accounts_total   = $null
    ready_to_reset   = $(if ($fmip -match "false") { $true } elseif ($blockers.Count) { $false } else { $null })
    reset_blockers   = $(if ($blockers.Count) { $blockers -join "; " } elseif ($fmip -match "false") { "" } else { "Find My status unknown: check Settings > [your name] > Find My" })
    move_first       = "Authenticator apps, banking/TAN apps, WhatsApp chat backup (iCloud), SIM card"
  }
}

function Add-SellCheck {
  param($Row, $Check)
  foreach ($p in $Check.PSObject.Properties) {
    $Row | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
  }
  $Row | Add-Member -NotePropertyName backup_path -NotePropertyValue $null -Force
  $Row | Add-Member -NotePropertyName backup_verified -NotePropertyValue $null -Force
}

function Print-SellCheck {
  param($Row)
  Write-Host ("Device name: {0} | security patch: {1} | bootloader: {2} | storage: {3}" -f $Row.market_name, $Row.security_patch, $Row.bootloader, $Row.storage)
  if ($Row.ready_to_reset -eq $true) {
    Write-Host "Reset blockers: none (no Google/brand account signed in)" -ForegroundColor Green
  } else {
    Write-Host ("Reset blockers: {0}" -f $Row.reset_blockers) -ForegroundColor Yellow
  }
  if ($Row.move_first) {
    Write-Host ("Move before reset: {0}" -f $Row.move_first) -ForegroundColor Yellow
  }
}

function Get-PhoneDirStats {
  param([string]$Serial, [string]$PhonePath)
  $cmd = "if [ -d '$PhonePath' ]; then find '$PhonePath' -type f -exec stat -c %s {} + | awk '{n++;s+=`$1}END{print n+0, s+0}'; else echo missing; fi"
  $out = (Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", $cmd) -AllowFail).Trim()
  if ($out -match "^(\d+)\s+(\d+)$") { return [pscustomobject]@{ Files = [int64]$Matches[1]; Bytes = [int64]$Matches[2] } }
  return $null
}

function Get-LocalDirStats {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Files = 0; Bytes = 0 } }
  $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
  $sum = ($files | Measure-Object -Property Length -Sum).Sum
  return [pscustomobject]@{ Files = [int64]$files.Count; Bytes = [int64]$(if ($sum) { $sum } else { 0 }) }
}

function Backup-Android {
  param([string]$Serial, [string]$Label)

  $base = if ($BackupDir) { $BackupDir } else { Join-Path $Root "backups" }
  $safeLabel = ($Label -replace "[^\w\-]+", "_").Trim("_")
  $dest = Join-Path $base ("{0}_{1}" -f $safeLabel, $Serial)
  $null = New-Item -ItemType Directory -Force -Path $dest
  Write-Step "Backing up $Serial to $dest ..."

  $sources = @(
    @{ Phone = "/sdcard/DCIM";                                         Local = "DCIM" },
    @{ Phone = "/sdcard/Documents";                                    Local = "Documents" },
    @{ Phone = "/sdcard/Recordings";                                   Local = "Recordings" },
    @{ Phone = "/sdcard/MIUI/sound_recorder";                          Local = "Recordings_MIUI" },
    @{ Phone = "/sdcard/Android/media/com.whatsapp/WhatsApp/Media";    Local = "WhatsApp" },
    @{ Phone = "/sdcard/WhatsApp/Media";                               Local = "WhatsApp_old" },
    @{ Phone = "/sdcard/Android/media/com.whatsapp.w4b/WhatsApp Business/Media"; Local = "WhatsApp_Business" },
    @{ Phone = "/sdcard/Telegram";                                     Local = "Telegram" }
  )

  $lines = @()
  $allOk = $true
  foreach ($s in $sources) {
    $phone = Get-PhoneDirStats -Serial $Serial -PhonePath $s.Phone
    if (-not $phone -or $phone.Files -eq 0) { continue }
    $local = Join-Path $dest $s.Local
    $null = New-Item -ItemType Directory -Force -Path $local
    Invoke-DeviceAdbWithTimeout -Serial $Serial -AdbArgs @("pull", "-a", "$($s.Phone)/.", $local) -TimeoutSeconds 7200 | Out-Null
    $got = Get-LocalDirStats -Path $local
    $ok = ($got.Files -eq $phone.Files -and $got.Bytes -eq $phone.Bytes)
    if (-not $ok) { $allOk = $false }
    $lines += "{0,-4} {1,-18} {2,6} files {3,10:N1} MB  (phone: {4} files)" -f $(if ($ok) { "OK" } else { "DIFF" }), $s.Local, $got.Files, ($got.Bytes / 1MB), $phone.Files
  }

  # Documents from Download (skip apps/archives/media dumps).
  $docList = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "find /sdcard/Download -maxdepth 2 -type f \( -iname '*.pdf' -o -iname '*.doc' -o -iname '*.docx' -o -iname '*.xls' -o -iname '*.xlsx' -o -iname '*.odt' -o -iname '*.ods' -o -iname '*.ppt' -o -iname '*.pptx' -o -iname '*.txt' -o -iname '*.csv' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' -o -iname '*.mp4' -o -iname '*.mov' \)") -AllowFail
  $docs = @($docList -split "`r?`n" | Where-Object { $_ -like "/sdcard/*" })
  if ($docs.Count) {
    $local = Join-Path $dest "Download_documents"
    $null = New-Item -ItemType Directory -Force -Path $local
    $failed = 0
    foreach ($f in $docs) {
      $r = Invoke-DeviceAdbWithTimeout -Serial $Serial -AdbArgs @("pull", "-a", $f.Trim(), $local) -TimeoutSeconds 600
      if ($r -notmatch "1 file pulled") { $failed++ }
    }
    if ($failed) { $allOk = $false }
    $lines += "{0,-4} {1,-18} {2,6} files  ({3} failed)" -f $(if ($failed) { "DIFF" } else { "OK" }), "Download_documents", ($docs.Count - $failed), $failed
  }

  # SMS, contacts, call log as text (readable without the phone).
  $msgDir = Join-Path $dest "Messages_Contacts"
  $null = New-Item -ItemType Directory -Force -Path $msgDir
  $exports = @(
    @{ File = "sms.txt";      Uri = "content://sms";                         Proj = "address:date:type:body" },
    @{ File = "contacts.txt"; Uri = "content://com.android.contacts/data";   Proj = "display_name:mimetype:data1" },
    @{ File = "call_log.txt"; Uri = "content://call_log/calls";              Proj = "number:name:date:duration:type" }
  )
  foreach ($e in $exports) {
    $text = Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "content", "query", "--uri", $e.Uri, "--projection", $e.Proj) -AllowFail
    Set-Content -LiteralPath (Join-Path $msgDir $e.File) -Value $text -Encoding UTF8
    $rows = ([regex]::Matches($text, "(?m)^Row: ")).Count
    $lines += "{0,-4} {1,-18} {2,6} rows" -f $(if ($rows -gt 0 -or $text -match "No result") { "OK" } else { "?" }), $e.File, $rows
  }

  $summary = @("Backup of $Label ($Serial), $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "") + $lines + @("", $(if ($allOk) { "All folders verified: file count and total size match the phone." } else { "Some folders did NOT match the phone. Do not reset until this is fixed." }))
  Set-Content -LiteralPath (Join-Path $dest "backup-summary.txt") -Value $summary -Encoding UTF8
  Write-Host ""
  $summary | ForEach-Object { Write-Host "  $_" }
  return [pscustomobject]@{ Path = $dest; Verified = $allOk }
}

function Backup-Ios {
  param($IosTools, [string]$Udid, [string]$Label)
  $tool = Find-IosTool "idevicebackup2.exe"
  if (-not $tool) {
    Write-Step "iOS backup skipped: idevicebackup2.exe not found. Use iCloud backup, or Apple Devices / iTunes on this PC."
    return [pscustomobject]@{ Path = $null; Verified = $false }
  }
  $base = if ($BackupDir) { $BackupDir } else { Join-Path $Root "backups" }
  $dest = Join-Path $base (("{0}_{1}" -f ($Label -replace "[^\w\-]+", "_"), $Udid))
  $null = New-Item -ItemType Directory -Force -Path $dest
  Write-Step "Full iPhone backup to $dest (can take a long time; keep the phone unlocked)..."
  $out = Invoke-IosTool -Exe $tool -ToolArgs @("-u", $Udid, "backup", "--full", $dest) -AllowFail
  $ok = $out -match "Backup Successful"
  Write-Step $(if ($ok) { "iPhone backup finished." } else { "iPhone backup did not report success. See log." })
  return [pscustomobject]@{ Path = $dest; Verified = [bool]$ok }
}

function Invoke-AndroidResetPrep {
  param([string]$Serial, $Row)

  Write-Host ""
  if ($Row.ready_to_reset -ne $true) {
    Write-Step "Not resetting ${Serial}: $($Row.reset_blockers)"
    Write-Host "  Remove these accounts first, otherwise the phone locks itself after the wipe." -ForegroundColor Yellow
    Write-Host "  Opening the Accounts screen on the phone..."
    Invoke-DeviceAdb -Serial $Serial -AdbArgs @("shell", "am", "start", "-a", "android.settings.SYNC_SETTINGS") -AllowFail | Out-Null
    Write-Host "  Xiaomi: also Settings > Mi Account > Sign out. Samsung: Settings > Accounts > Samsung account > Sign out."
    Write-Host "  Then run sellprep.cmd again."
    return
  }
  if ($Backup -and $Row.backup_verified -ne $true) {
    Write-Step "Not resetting ${Serial}: the backup is not verified."
    return
  }
  if ($Row.move_first) {
    Write-Host "  Before you continue, make sure these are moved: $($Row.move_first)" -ForegroundColor Yellow
  }

  $last4 = $Serial.Substring([math]::Max(0, $Serial.Length - 4))
  Write-Host ""
  Write-Host "  $($Row.market_name) $($Row.model) ($Serial) will reboot into recovery." -ForegroundColor Cyan
  Write-Host "  Everything on it is erased once you pick the wipe option on the phone."
  $answer = Read-Host "  Type ERASE $last4 to continue (anything else cancels)"
  if ($answer -cne "ERASE $last4") {
    Write-Step "Reset cancelled for $Serial."
    return
  }
  Write-Step "Rebooting $Serial into recovery..."
  Invoke-DeviceAdb -Serial $Serial -AdbArgs @("reboot", "recovery") -AllowFail | Out-Null
  Write-Host ""
  Write-Host "  On the phone (volume keys move, power selects; Xiaomi/POCO allow touch):" -ForegroundColor Cyan
  Write-Host "    Xiaomi/POCO/Redmi: Wipe Data > Wipe All Data > Confirm"
  Write-Host "    Samsung:           Wipe data/factory reset > Factory data reset"
  Write-Host "    Pixel/Motorola:    Factory data reset > Factory data reset"
  Write-Host "    Then: Reboot system. It is done when the phone shows the language/welcome screen."
}

function Show-IosResetSteps {
  param($Row)
  Write-Host ""
  Write-Host "  iPhone/iPad reset (Apple does not allow starting it over USB):" -ForegroundColor Cyan
  Write-Host "    1. Settings > [your name] > Find My > Find My iPhone > off"
  Write-Host "    2. Settings > General > Transfer or Reset iPhone > Erase All Content and Settings"
  Write-Host "    That also signs out of iCloud and removes Activation Lock."
}
