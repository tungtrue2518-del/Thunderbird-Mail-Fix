---
name: windows-autofix-tool
description: Build an "Overall Autofix" tool for a Windows desktop app (Thunderbird, Outlook, ...) the way Thunderbird Mail Fix was built - one PowerShell file with a Thai WinForms UI, packed into a single self-elevating .exe, that scans every account, fixes what it can, explains the rest, and is proven with dry tests on fake profiles. Use when the user asks for a new autofix / repair / "fix everything" tool for IT, a new version of Thunderbird Mail Fix, or the Outlook version.
---

# Windows Autofix Tool

Reference implementation: https://github.com/tungtrue2518-del/Thunderbird-Mail-Fix
(`Thunderbird-Fix-Tool.ps1`, `build.ps1`, `build/Launcher.cs`, `tests/`). Read it before starting a new tool - copy
the structure, do not reinvent it.

The user is an IT admin. They write in Thai; the UI, README and release notes are Thai, code comments English.
They share tools with IT colleagues through GitHub and the company file share, and judge the tool by
"does it really fix it, and does it never break or hang".

## Product rules (what the user expects)

1. **Scan first, per account.** On open, scan automatically and list every account with a status:
   🟢 ปกติ / 🔴 มีปัญหา (auto-ticked) / 🟠 ควรตรวจสอบ. Click an account -> details with the cause in plain Thai.
2. **Buttons:** แก้ไขอัตโนมัติทุกบัญชีที่มีปัญหา (fix all red) · แก้ไขบัญชีที่เลือก · Optimize · test login
   (receive + send) · open the app normally / safe mode / profile manager · + add profile by hand.
3. **Fix, then rescan to prove it.** Re-read config after a fix (cached settings gave false "still broken").
4. **Fixable vs advice.** Every issue is `@{ Code; Text; Fixable }`. 🔧 fix it. 💡 server / network / password /
   policy problems: explain the cause and the exact menu path to fix it - never pretend.
5. **Never lose data.** Nothing is deleted: files are *moved* to `Desktop\<Tool>-Backup-<date>` with a log;
   config files (prefs.js, profiles.ini, ...) and important databases are copied there before any edit.
6. **Close the app properly first** (CloseMainWindow, wait 15 s, then force). If it will not close: change nothing.
   An app that is stuck in the background (holds the profile lock, no window / not responding) is ended at once -
   this replaces "restart the PC".
7. **Passwords:** only for the login test, typed by the user, memory only, never logged, never saved, never
   decrypted from the app's own store. The login test never sends mail.
8. **"Overall" means broad:** cover write errors, not receiving, not sending, app will not open / crashes /
   "all mail gone" (wrong default profile), slow (Optimize), and the tool's own start-up problems.

## Architecture (one .ps1)

```
self-elevate (Resolve-RealPath for mapped/SUBST drives, TBFIX_RELAUNCHED guard, "No" on UAC = continue limited)
$AppVersion = 'x.y.z'          <- build.ps1 reads this for the exe version
single instance: Mutex (catch access-denied = an admin copy owns it) -> AppActivate(window title) -> else offer to
                 end a stuck old copy (find by exe name or "-File <tool>.ps1")
$engine = { param($sync, $opt) ... }   <- ALL disk/network work, runs in a background runspace
UI (WinForms, Thai, Leelawadee UI font) + Timer (120 ms) that drains $sync.Queue into the log and reads results
```

- `$sync = [hashtable]::Synchronized(@{ Queue = ConcurrentQueue; Progress; StatusText; Done; Results; ... })`.
  The engine only talks through `$sync`; the UI never blocks.
- Engine modes: `scan`, `fix` (Targets = account keys), `optimize`, `login` (one account, password in `$opt`).
  Every mode ends with a rescan and sets `$sync.Done` in `finally`.
- Discovery must be generous: every Windows user (ProfileList, expand `%VARS%`), normal + Microsoft Store
  (`AppData\Local\Packages\*<App>*\LocalCache\Roaming\...`) locations, config file missing or wrong, plus the
  app's profile folder scanned directly, plus profiles picked by hand.
- Network checks always with timeouts (DNS via BeginGetHostAddresses, TCP BeginConnect 5 s), cached per host:port.
- Who locks a file: Windows Restart Manager (`rstrtmgr.dll` via Add-Type) -> name the program.
- SQLite without installing anything: `winsqlite3.dll` (built into Windows 10/11) via P/Invoke.
- Every `Add-Type` inside `try { } catch { return $false }` - antivirus/AppLocker can block the compiler.
- Every MessageBox after the form exists: `[Windows.Forms.MessageBox]::Show($form, ...)` (owner!).
- FormClosing: ask only when `CloseReason -eq 'UserClosing'`; otherwise stop the engine and exit.
  End of script: `if ($PSCommandPath) { [Environment]::Exit(0) }`.

## The exe (build.ps1 + build/Launcher.cs)

- C# launcher compiled with the .NET Framework `csc.exe` that ships with Windows (`/codepage:65001`), the script
  embedded as resource `tool.ps1`, run in-process in an STA runspace (`PSThreadOptions.UseCurrentThread`).
- Manifest `asInvoker`; the launcher elevates itself (`runas`, arg `--elevated`) using the real path
  (`WNetGetConnection` / `QueryDosDevice`) and continues limited when UAC is declined.
- Set `PSExecutionPolicyPreference=Bypass` for the process (covers the background runspace too).
- If the window never appeared (`TbFixUiShown` not set) and there were errors: show them in a MessageBox and log
  to `%TEMP%\<Tool>-errors.log`. Always `Environment.Exit` at the end.
- Icon: draw it with System.Drawing; .ico with 256 px as PNG and smaller sizes as 32-bit DIB
  (System.Drawing cannot read PNG entries).

## Windows PowerShell 5.1 pitfalls (all hit for real)

| Pitfall | Fix |
|---|---|
| Thai text garbled | save every .ps1 as **UTF-8 with BOM** (re-save after each edit) |
| `$c = ...` inside a function hides `$C` (names are case-insensitive) | never reuse a global's name in another case |
| A single PSCustomObject has no `.Count` | wrap: `@(Get-Things)` |
| `$opt.Keys` returns the hashtable's keys, not your entry | do not name entries Keys / Values / Count |
| `[char]0x25CF + 'text'` throws | `[string][char]0x25CF + 'text'` |
| `$a, $b = switch {...}` with `'x', $y + 'z'` | parenthesise: `'x', ($y + 'z')` |
| `-match` inside an `if` overwrites `$Matches` | copy `$Matches[1]` before the next match |
| Native-exe arguments with quotes get split (git commit -m) | write the text to a file, pass `-F file` |
| Glyphs ✔ ✖ ▸ missing in Leelawadee UI | draw them with `Segoe UI Symbol` (RichTextBox runs) |
| Un-owned MessageBox can open behind everything = "hang" | pass `$form` as owner |
| Closing mid-scan left the process alive = "stuck until restart" | BeginStop the runspace + `Environment.Exit` |
| `python` on this PC opens the Store and hangs | edit with the Edit tool / PowerShell, not Python |

## Dry tests (keep them in `tests/` in the repo - the scratchpad gets wiped)

- Build fake profiles under `$env:TEMP\<name>`; set `$env:USERPROFILE` / `$env:TEMP` to the fake root.
- Run a **patched copy** of the tool: replace `Get-Process <app>` with a dummy name, `GetFolderPath('Desktop')`
  with the fake desktop, and the mutex name - never touch the real app, real profile or real Desktop.
- Fake servers with `TcpListener` in a runspace (POP3: `+OK`/`-ERR [AUTH]`; SMTP: 220/250 AUTH/235/535).
- Engine-only checks: extract `$engine` with the PowerShell AST and run it directly.
- GUI checks with UI Automation: find windows by **ProcessId** (desktop-wide name search is unreliable); dialogs
  owned by the main window are its children; click with `PostMessage(BM_CLICK)`; type with `WM_SETTEXT`; select a
  ListView row with WM_LBUTTONDOWN; WinForms drop-downs are a `Pane` with no items (verify by screenshot) and close
  at once unless the window is activated first (`AppActivate`).
- Screenshots with `PrintWindow(hwnd, hdc, 2)`, then look at them.
- Simulate "stuck" with a hidden process holding the lock file with `FileShare.None` (wait > 60 s - younger
  processes are treated as still starting); simulate a stuck old copy with a process holding the mutex.
- After every run: no leftover test processes. Run every suite for **script and exe** before a release.

## Release checklist

1. Parse check + BOM; `$AppVersion` bumped.
2. Dry tests: feature suite (script + exe) and launch suite - all PASS.
3. Real PC: **scan only** (never fix / optimize / login on the real profile without the user's go-ahead).
4. `git grep` for company names, e-mail addresses, server names before every push.
5. `build.ps1`; replace the Desktop copy (if it is running the file is locked - ask the user to close it, never kill it).
6. Commit (message via file, attribution trailer), push, `gh release create vX.Y.Z exe ps1` with **Thai** notes
   (download table, what's new, how to use, test results), screenshot from fake data only.
7. Copy to the share folder where the previous exe lives (look first - the folder name may differ slightly from what was typed), then
   verify the same SHA256 on Desktop, GitHub and the share.
8. README grouped by symptom, a contents line, each topic once; version history as a short table.

## Starting the Outlook version (notes to verify, not facts)

Same rules and architecture; new detection/fix catalogue. Things to research and confirm on a real machine:
- Profiles: `HKCU\Software\Microsoft\Office\16.0\Outlook\Profiles\<name>` (MAPI), default profile, accounts per
  profile; Classic Outlook only - the "new Outlook" (olk.exe) has no PST/OST.
- Data files: OST `%LOCALAPPDATA%\Microsoft\Outlook`, PST usually `Documents\Outlook Files`; size limits
  (50 GB default), read-only / permissions / on OneDrive or a network share; `SCANPST.EXE` in the Office folder
  (Inbox Repair Tool); a damaged OST can be renamed so Outlook rebuilds it (Exchange/IMAP only, never a POP PST).
- Start-up switches: `/safe`, `/resetnavpane`, `/cleanviews`, `/cleanreminders`, `/resetfolders`, `/profiles`.
- Stuck `OUTLOOK.EXE` in the background, add-ins (registry `...\Outlook\Addins`, `LoadBehavior`), crash events.
- Mail not arriving / not sending: same POP3/IMAP/SMTP login tests; Exchange/M365 accounts = Autodiscover and
  modern auth - explain, do not try to log in.
- Office repair: Click-to-Run Quick Repair (`OfficeClickToRun.exe scenario=Repair ...`) - confirm before using.
