# WinTool

A WinUtil-style PowerShell GUI you run with a single `irm | iex` command.
The GUI is a shell (`main.ps1`) that pulls its tabs from `manifest.json` at
runtime, so adding new task categories later never requires changing the
one-liner people run.

```
winscript/
├── bootstrap.ps1              <- the ONLY file end users run
├── main.ps1                   <- GUI shell, loads modules from manifest.json
├── manifest.json              <- list of tabs/modules to load
├── modules/
│   ├── Debloat.ps1            <- "Debloat" tab
│   └── _ModuleTemplate.ps1    <- copy this to add a new tab
└── config/
    └── debloat-list.json      <- checklist data used by Debloat.ps1
```

## 1. Host it on GitHub

1. Create a **public** repo, e.g. `github.com/yourusername/wintool`.
2. Push these files to the `main` branch, keeping the folder structure above.
3. Edit **two places** to point at your repo:
   - `bootstrap.ps1` → `$Global:BaseRepoUrl`
   - `main.ps1` → the fallback `$Global:BaseRepoUrl` (only used if someone
     dot-sources main.ps1 directly during local testing)

## 2. Run it

```powershell
irm https://raw.githubusercontent.com/yourusername/wintool/main/bootstrap.ps1 | iex
```

`bootstrap.ps1` will:
1. Set TLS 1.2 (needed on older Windows PowerShell for GitHub raw content).
2. Relaunch itself elevated (UAC prompt) if not already running as Administrator.
3. Download and run `main.ps1`, which downloads `manifest.json` and every
   module listed in it, and builds the GUI.

Every run always pulls the latest version of every file from GitHub — there's
no local install and no versioning to manage. Push a change, and the next
person who runs the command gets it immediately.

## 3. Add your own tasks later

You said you'd specify custom tasks later — when you're ready, do this for
each new category:

1. Copy `modules/_ModuleTemplate.ps1` → `modules/YourFeature.ps1`.
2. Rename `Get-TemplateTab` to something unique, e.g. `Get-TweaksTab`, and
   build whatever WPF controls (checkboxes, buttons, dropdowns...) you need.
3. Add a line to `manifest.json`:
   ```json
   { "name": "Tweaks", "file": "modules/Tweaks.ps1", "function": "Get-TweaksTab" }
   ```
4. Commit and push. That's it — `main.ps1` doesn't need to change.

Inside a module you get, for free:
- `$BaseRepoUrl` — your repo's raw base URL, for fetching more JSON/config.
- `Write-Log "message"` — quick log line from the UI thread.
- `Start-BackgroundTask -Work { param($SyncHash, ...) ... } -ArgumentList @(...) -OnDone { ... }`
  — runs work on a background runspace so the GUI stays responsive. Inside
  `-Work`, log with `$SyncHash.LogQueue.Enqueue("text")` (the `-Work`
  scriptblock only sees what you pass through `-ArgumentList`, not variables
  from the module's own scope).

## Notes / scope

- Windows-only (WPF). Requires Windows PowerShell 5.1 or PowerShell 7+ on Windows.
- Always self-elevates to Administrator, since most system tweaks require it.
- This scaffold intentionally does **not** include any Windows/Office
  activation-bypass functionality (à la MassGrave) — that facilitates
  license circumvention and is out of scope.
- Test changes locally first: `. .\main.ps1` after manually setting
  `$Global:BaseRepoUrl`, or better, temporarily point `bootstrap.ps1` at a
  `dev` branch/tag before merging to `main`.
