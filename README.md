# ChargeLimit

A small native macOS menu bar app for setting a battery charge limit on Apple Silicon Macs.

Click the power-plug icon in the menu bar to get a Control Center-style dropdown with a slider that snaps to **80%, 85%, 90%, 95%, or 100%**, your current battery percentage and charging status, and a "Turn off for today" switch that disables the limit until midnight (it auto-re-applies your saved value at 00:00).



## Why
While macOS allows you to set a charge limit, you must access the settings to do so. This app provides a clean and convenient menu bar toggle for this purpose. 


## How it works

Apple Silicon has no `BCLM` equivalent — there's no SMC register that means "limit charging to 85%". To enforce any limit between 80 and 100, something has to poll the battery percentage and toggle the `CH0C` SMC key (pause/resume charging) when the threshold is hit. That's a privileged daemon.

ChargeLimit doesn't ship its own daemon. Instead it wraps [`batt`](https://github.com/charlie0129/batt) — a well-maintained open-source MIT-licensed daemon that already does this correctly. ChargeLimit is just a thin SwiftUI front-end that shells out to `batt limit <N>` / `batt disable`.

## Requirements

- macOS on Apple Silicon (M1 or newer)
- [`batt`](https://github.com/charlie0129/batt) installed and its daemon running
- Swift toolchain (Xcode or Command Line Tools) — only needed to build

## Install

```sh
# 1. Install batt and start its launchd daemon (one-time; needs sudo because the
#    daemon runs as root to write the SMC charging key)
brew install batt
sudo brew services start batt

# 2. Build and launch ChargeLimit
git clone https://github.com/quittnet/charge-limit.git
cd charge-limit
./launch.sh
```

`launch.sh` compiles `ChargeLimit.swift` with `swiftc` and starts the menu bar app via `nohup`. If you launch it before `batt` is installed, the dropdown shows an install prompt with a "Copy install command" button — install `batt`, then click **Recheck**.

To stop:

```sh
./stop.sh
```

## What's in the dropdown

- **Charge Limit** label + slider (80–100 in 5% steps) + current value
- Battery icon, current battery percentage, and charging status ("Charging" / "Plugged in, not charging" / "On battery"), refreshing every 2 seconds while the popup is open
- A native switch for **Turn off for today** — flips it on to disable the limit; it auto-re-applies your saved value at the next midnight, or you can flip the switch back off to resume immediately

## Files

| File | Purpose |
|---|---|
| `ChargeLimit.swift` | Single-file Swift source — model, IOKit battery reader, `batt` wrapper, AppDelegate, SwiftUI view |
| `launch.sh` | Build (if needed) and start the app via `nohup` |
| `stop.sh` | `pkill` the running app |

## Build manually

```sh
swiftc ChargeLimit.swift -o ChargeLimit -framework AppKit -framework SwiftUI
./ChargeLimit
```



