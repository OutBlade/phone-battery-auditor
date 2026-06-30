# Compatibility

| Platform | Source | Status |
| --- | --- | --- |
| Samsung One UI | `dumpsys battery` vendor fields | Tested on SM-S918B |
| Pixel / AOSP | `/sys/class/power_supply/battery/*` | Best effort |
| OnePlus / Oppo / Realme | `/sys/class/oplus_chg/battery/*` | Best effort |
| Xiaomi / Redmi / POCO | mixed vendor diagnostics | Needs reports |
| iPhone / iPad | libimobiledevice `AppleSmartBattery` | Best effort |

## Known Sources

- `dumpsys battery`
- `/sys/class/power_supply/battery/cycle_count`
- `/sys/class/power_supply/battery/charge_full`
- `/sys/class/power_supply/battery/charge_full_design`
- `/sys/class/qcom-battery/battery/*`
- `/sys/class/oplus_chg/battery/*`
- `idevicediagnostics ioregentry AppleSmartBattery`

Unknown fields are reported as `unknown`.
