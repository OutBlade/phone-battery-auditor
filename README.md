# Android Battery Auditor

One-click Windows battery health checker for USB-authorized Android phones.

Connect a phone, allow USB debugging, run `run.cmd`, and get a clean HTML/CSV
report on the computer. The default mode does not install apps and does not touch
the phone UI.

```text
Device: samsung SM-S918B / Android 16
Maximum capacity: 88%
Cycles: 822.37 estimated from Samsung usage
First use date: 20230803
Confidence: high
```

## Why

Android has no single iPhone-style battery health screen across all brands. Some
phones expose health and cycle data through ADB, but the fields differ by vendor.
This tool collects the known sources and labels where each result came from.

## Quick Start

1. On the phone, enable `Developer options`.
2. Enable `USB debugging`.
3. Connect the phone by USB.
4. Tap `Allow USB debugging` on the phone.
5. Run:

```bat
run.cmd
```

The HTML report opens automatically. CSV and logs are saved in `reports\` and
`logs\`.

## What Works Best

| Brand | Status | Notes |
| --- | --- | --- |
| Samsung One UI | Best tested | Reads `mSavedBatteryAsoc`, `mSavedBatteryUsage`, `mSavedBatteryBsoh`, first-use date |
| Pixel / AOSP | Best effort | Tries `cycle_count`, `charge_full`, `charge_full_design` |
| OnePlus / Oppo / Realme | Best effort | Tries `oplus_chg` paths such as `battery_fcc`, `battery_soh` |
| Xiaomi / Redmi / POCO | Best effort | Vendor support varies heavily; real-device reports needed |

If a phone hides a field, the report shows `unknown` instead of inventing a fake
number.

## Commands

```bat
run.cmd
```

Run the audit and open the HTML report.

```bat
run.cmd -ListOnly
```

Show connected ADB devices.

```bat
run.cmd -Device SERIAL
```

Audit one selected device.

```bat
run.cmd -NoOpenReport
```

Save reports without opening the browser.

## Optional App Setup

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

- `high`: direct vendor health value, direct sysfs health value, or full/design
  capacity calculation.
- `estimate`: calculated from current charge counter and battery percentage.
- `unknown`: the phone did not expose enough data.

For Samsung, `mSavedBatteryUsage / 100` is shown as estimated full cycles because
Samsung stores accumulated discharge percentage there.

## Popularity Checklist

- Star the repo if it worked for your phone.
- Open an issue with your phone model and report output if any field is unknown.
- Share screenshots of the HTML report, not phone screenshots.
- Add compatibility results for different brands.

## Safety

Android requires the user to explicitly allow USB debugging. This tool does not
try to bypass Android security prompts.
