# adobe_services_disabler

Turn off everything Adobe runs in the background, on macOS and Windows. One
command switches it all off; the same command switches it all back on.

Creative Cloud installs a set of helpers, updaters and telemetry agents that
start with your machine and keep running whether or not you ever open a Creative
Cloud app. These two scripts find them by wildcard, switch them off in the place
that actually keeps them off, and stop the ones already running. Nothing is
deleted, so Enable genuinely puts everything back.

Website: <https://dandanilyuk.github.io/adobe_services_disabler/>

## Run it

Read the script before you run it. Both are plain text and linked below.

**macOS**

```sh
/bin/bash -c "$(curl -fsSL https://dandanilyuk.github.io/adobe_services_disabler/disable_adobe_services.sh)"
```

**Windows** (use an Administrator window to cover machine-wide items)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://dandanilyuk.github.io/adobe_services_disabler/disable_adobe_services.ps1 | iex"
```

## There are no arguments

Both scripts are menu-driven and take no flags or options at all. Run one and it
prints what Adobe currently has installed and what state each item is in, then
offers three choices:

```
  Disable Adobe startup services
  Enable Adobe startup services
  Quit
```

Arrow keys move, Enter selects, `q` or Esc backs out. Nothing is touched until
you pick Disable or Enable, so quitting is always safe.

### Prefer to inspect before running

That is the better habit for anything you pipe into a shell. On macOS, press `q`
when you are done reading and the script starts at its menu:

```sh
curl -fsSLO https://dandanilyuk.github.io/adobe_services_disabler/disable_adobe_services.sh &&
less disable_adobe_services.sh &&
bash disable_adobe_services.sh
```

On Windows, Notepad opens beside the script, which waits at its menu while you
read. `-File` with `Bypass` is needed because Windows refuses a bare
`.\disable_adobe_services.ps1` under its default execution policy:

```powershell
$f = "$env:TEMP\disable_adobe_services.ps1"
irm https://dandanilyuk.github.io/adobe_services_disabler/disable_adobe_services.ps1 -OutFile $f
notepad $f
powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

A downloaded copy deletes itself once it finishes, so nothing is left lying
around. A copy inside a git checkout is left alone, and when the script is piped
straight into a shell there is no file to remove in the first place.

## What it actually touches

**macOS** (`disable_adobe_services.sh`)

- **launchd agents and daemons** - every `com.adobe.*.plist` in
  `/Library/LaunchAgents`, `~/Library/LaunchAgents` and `/Library/LaunchDaemons`
  is booted out and marked disabled, so it stays off across reboots. Found by
  wildcard, so it still works after an Adobe update recreates them.
- **App extensions** - Finder Sync (`ACCFinderSync`) and the right-click
  extension are switched off with `pluginkit -e ignore`. macOS relaunches these
  itself, so this is the only level at which they stay off.
- **Running helpers** - anything whose executable path contains `adobe` is
  stopped, *except* the creative apps under `/Applications/Adobe*` (Photoshop,
  Lightroom, Acrobat, and the rest). The Creative Cloud desktop app is a
  helper and is stopped.

sudo is requested once, and only if Adobe system daemons are present. Decline it
and everything else is still applied.

**Windows** (`disable_adobe_services.ps1`)

- **Services** - stopped, and their start type set to Disabled. The original
  start type is recorded under `HKCU:\Software\adobe_services_disabler` first, so
  Enable restores Manual rather than forcing everything to Automatic.
- **Scheduled tasks** - the updater and telemetry tasks, disabled in place.
- **Startup entries** - Run and RunOnce keys, plus shortcuts in the user and
  all-users Startup folders, flipped using the same `StartupApproved` flag
  Task Manager's Startup tab writes. Nothing is deleted.
- **Running helpers** - background processes stopped; creative apps never are.

Without Administrator rights the machine-wide items are skipped and only
per-user items are handled. The script says so up front.

## Known limitations

- **The Windows script has never been run on a real Windows machine.** It was
  written and reviewed carefully, and it parses as balanced PowerShell, but it
  has not been executed. Treat the first run as a test. Reports welcome.
- Opening the Creative Cloud desktop app can respawn some helpers until your
  next reboot. They stay off after that.
- Adobe installers recreate their launch items during updates. Re-run the
  command whenever that happens; it rediscovers whatever exists.
- On macOS, also check System Settings > General > Login Items and turn off
  anything from Adobe listed there. Those are not launchd items.

## Repository layout

| File | |
| --- | --- |
| `disable_adobe_services.sh` | The macOS script. |
| `disable_adobe_services.ps1` | The Windows script. |
| `index.html`, `style.css`, `main.js`, `theme-init.js` | The landing page, served by GitHub Pages from the repo root. |

## License

MIT. See [LICENSE](LICENSE).
