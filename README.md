# Phone Battery Auditor

One-click Windows battery health checker for Android phones, iPhone, and iPad.

Connect a device, trust/authorize the computer, run `run.cmd`, and get a clean
HTML/CSV report on the computer. The default mode does not install apps and does
not touch the phone UI.

```text
Samsung SM-S918B / Android 16
Maximum capacity: 88%
Cycles: 822.37 estimated from Samsung usage
Confidence: high
```

## Why

Resellers and repair shops need a fast battery report without opening multiple
apps. Android and iOS expose battery data through different USB protocols, so
this tool collects the known sources and labels where each result came from.

## Quick Start

1. Connect the phone by USB.
2. Do the one-time trust step:
   - Android: enable `Developer options`, enable `USB debugging`, tap `Allow USB debugging`.
   - iPhone/iPad: unlock the device and tap `Trust This Computer`.
3. Run:

```bat
run.cmd
```

The HTML report opens automatically. CSV and logs are saved in `reports\` and
`logs\`.

## What Works Best

| Platform | Status | Notes |
| --- | --- | --- |
| Samsung One UI | Best tested | Reads `mSavedBatteryAsoc`, `mSavedBatteryUsage`, `mSavedBatteryBsoh`, first-use date |
| Pixel / AOSP | Best effort | Tries `cycle_count`, `charge_full`, `charge_full_design` |
| OnePlus / Oppo / Realme | Best effort | Tries `oplus_chg` paths such as `battery_fcc`, `battery_soh` |
| Xiaomi / Redmi / POCO | Best effort | Vendor support varies heavily; real-device reports needed |
| iPhone / iPad | Best effort | Uses libimobiledevice `AppleSmartBattery` over USB after Trust This Computer |

If a device hides a field, the report shows `unknown` instead of inventing a fake
number.

## Selling a device (fork additions)

One command for phones, one for the laptop you are sitting at:

```bat
sellprep.cmd
```

For every connected Android phone / iPhone this:

1. Prints battery health (maximum capacity, cycles) plus device name, security patch, bootloader state and storage.
2. Lists **reset blockers**: signed-in Google / Xiaomi / Samsung / Huawei / OPPO accounts. A phone wiped with those
   still signed in stays locked to that account (Factory Reset Protection).
3. Lists **move first** apps: authenticators, pushTAN / SecureGo, AusweisApp, WhatsApp, Wallet, and an inserted SIM.
4. Backs up photos (DCIM), WhatsApp / Telegram media, Documents, recordings, documents from Download,
   and SMS / contacts / call log as text into `backups\<device>_<serial>\`, then **verifies file count and size
   against the phone** (`backup-summary.txt`).
5. Only if there are no blockers and the backup verified: asks you to type `ERASE <last 4 of serial>`, reboots the
   phone into recovery and tells you which menu item wipes it. Nothing is erased by the tool itself.
   iPhone: prints the Erase All Content and Settings steps (Apple does not allow starting a wipe over USB).

`backups\` is git-ignored. It contains personal data; keep it off GitHub.

Windows laptop (this PC): battery capacity from `powercfg /batteryreport`, model, serial, CPU, RAM, disks, BitLocker:

```bat
thispc.cmd          & rem report only
thispc.cmd -Reset   & rem report, then open Windows "Reset this PC" after typing RESET
```

MacBook (run on the Mac): battery capacity and cycles from `AppleSmartBattery`, Find My Mac status,
optional Erase All Content and Settings:

```bash
bash scripts/mac-sellprep.sh          # report only
bash scripts/mac-sellprep.sh --reset  # then open Erase Assistant after typing ERASE
```

iPhone support needs libimobiledevice in `tools\libimobiledevice\`. The fork no longer downloads the unofficial
build automatically; pass `-AllowIosDownload` to allow it.

## Commands

```bat
run.cmd
```

Audit Android and iPhone/iPad devices and open the HTML report.

```bat
run.cmd -ListOnly
```

Show connected devices.

```bat
run.cmd -AndroidOnly
run.cmd -IosOnly
```

Scan only one platform.

```bat
run.cmd -Device SERIAL_OR_UDID
```

Audit one selected device.

```bat
run.cmd -NoOpenReport
```

Save reports without opening the browser.

## Optional Android App Setup

Default mode does not require aBattery or Shizuku. If you still want app setup,
put a trusted `aBattery.apk` at:

```text
apks\abattery.apk
```

Then run:

```bat
run.cmd -SetupApps
```

Opening phone UI is intentionally opt-in:

```bat
run.cmd -LaunchApp
```

## Output

```text
reports\battery-audit-YYYYMMDD-HHMMSS.html
reports\battery-audit-YYYYMMDD-HHMMSS.csv
logs\battery-audit-YYYYMMDD-HHMMSS.log
```

## Accuracy

The report includes `confidence`:

- `high`: direct vendor health value, direct sysfs health value, AppleSmartBattery
  full/design capacity, or full/design capacity calculation.
- `estimate`: calculated from current charge counter and battery percentage.
- `partial`: some battery data was found, but not enough for a health value.
- `unknown`: the device did not expose enough data.

For Samsung, `mSavedBatteryUsage / 100` is shown as estimated full cycles because
Samsung stores accumulated discharge percentage there.

For iPhone/iPad, the tool reads AppleSmartBattery fields such as `CycleCount`,
`DesignCapacity`, `AppleRawMaxCapacity`, and `NominalChargeCapacity` when the
device exposes them. Apple Settings may round or calibrate the displayed
percentage differently.

## Popularity Checklist

- Star the repo if it worked for your phone.
- Open an issue with your model and report output if any field is unknown.
- Share screenshots of the HTML report, not phone screenshots.
- Add compatibility results for different brands.

## Safety

Android requires the user to explicitly allow USB debugging. iPhone/iPad requires
the user to tap `Trust This Computer`. This tool does not try to bypass Android
or Apple security prompts.
