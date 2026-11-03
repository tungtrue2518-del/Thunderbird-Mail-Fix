<#
    Thunderbird Mailbox Fix Tool  (single-file PowerShell app with a window)

    Fixes the Thunderbird error:
      "Unable to write the email to the mailbox. Make sure the file system allows
       you write permission, and you have enough disk space to copy the mailbox."
      (ไม่สามารถเขียนอีเมลไปยังกล่องจดหมายได้ ...)

    It scans every mail account configured in Thunderbird (all Windows users on
    the PC when run as Administrator), shows which accounts have a problem, and
    fixes the selected accounts - or all broken accounts with one click.

    Checks per account: folder permissions, read-only files, locked mailboxes,
    broken .msf indexes, failed-compact leftovers, mailboxes over 4 GB, missing
    Local Directory, "check for new mail" turned off, incoming/outgoing server
    reachable (DNS + port), saved password, mail stuck in the Outbox, disk space,
    FAT32 and cloud-sync folders.

    HOW TO RUN (on the broken PC):
      Right-click this file > "Run with PowerShell"
      or:  powershell -ExecutionPolicy Bypass -File .\Thunderbird-Fix-Tool.ps1

    The tool asks for Administrator rights by itself. Nothing is permanently
    deleted: files it removes from a mail folder are moved to a backup folder on
    the Desktop ("Thunderbird-Fix-Backup-<date>").
#>

# --- Self-elevate to Administrator ----------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# An elevated process cannot see mapped network drives (Z:) or SUBST drives of the normal user,
# so relaunch with the real path: \\server\share\... or the folder behind the SUBST letter.
function Resolve-RealPath([string]$path) {
    if (-not $path -or $path -like '\\*') { return $path }
    $drive = $path.Substring(0, 2)
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction Stop
        if ($disk.DriveType -eq 4 -and $disk.ProviderName) { return $disk.ProviderName.TrimEnd('\') + $path.Substring(2) }
    } catch {}
    foreach ($line in @(& subst.exe 2>$null)) {
        if ($line -match "^$([regex]::Escape($drive))\\: => (.+)$") { return $Matches[1].TrimEnd('\') + $path.Substring(2) }
    }
    $path
}
# TBFIX_RELAUNCHED stops a relaunch loop; TBFIX_TEST_NO_RUNAS lets the dry test relaunch without a UAC prompt
if (-not $isAdmin -and $PSCommandPath -and $env:TBFIX_RELAUNCHED -ne '1') {
    try {
        $env:TBFIX_RELAUNCHED = '1'
        $relaunch = @{ FilePath = 'powershell.exe'; ErrorAction = 'Stop'; ArgumentList = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$(Resolve-RealPath $PSCommandPath)`"") }
        if ($env:TBFIX_TEST_NO_RUNAS -ne '1') { $relaunch.Verb = 'RunAs' }
        Start-Process @relaunch
        exit
    } catch { $env:TBFIX_RELAUNCHED = $null }   # user pressed "No" on UAC - continue without admin
}

$AppVersion = '1.3.0'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Only one copy at a time (two copies fixing the same profile would fight over the files) ---
# Copies of this tool: the exe (whatever it was renamed to) or powershell running this script.
function Get-OtherCopies {
    $self = [Diagnostics.Process]::GetCurrentProcess()
    $exeName = if ($self.ProcessName -notmatch '^powershell(_ise)?$') { "$($self.ProcessName).exe" }
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and $_.SessionId -eq $self.SessionId -and (
            ($exeName -and $_.Name -eq $exeName) -or
            ($_.Name -eq 'powershell.exe' -and $_.CommandLine -and
             $(if ($_.CommandLine -match '-File\s+"([^"]+)"' -or $_.CommandLine -match '-File\s+(\S+)') { (Split-Path $Matches[1] -Leaf) -like 'Thunderbird-Fix-Tool*.ps1' })))
    })
}
function Get-SingleInstance([int]$waitMs) {
    try { $script:mutex.WaitOne($waitMs) } catch [Threading.AbandonedMutexException] { $true }   # old copy crashed: lock is ours
}
$mutexName = 'ThunderbirdMailFix-SingleInstance'
try { $mutex = New-Object Threading.Mutex($false, $mutexName) }
catch { $mutex = $null }   # access denied: a copy running as Administrator owns it
if (-not $mutex -or -not (Get-SingleInstance 0)) {
    # already open: bring that window to the front by its title (works whichever process owns it,
    # even while it shows a menu or a dialog, and even if it runs as Administrator)
    try { [Microsoft.VisualBasic.Interaction]::AppActivate('Thunderbird Mailbox Fix Tool'); return } catch {}
    $others = Get-OtherCopies
    # an open window of this tool, however it was started (exe, script, renamed, as Administrator)
    $mySession = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $win = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Id -ne $PID -and $_.SessionId -eq $mySession -and $_.MainWindowTitle -eq 'Thunderbird Mailbox Fix Tool' }) +
        @($others | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue } |
            Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }) | Select-Object -First 1
    if ($win) {   # already open: bring that window to the front instead of opening a second one
        try { [Microsoft.VisualBasic.Interaction]::AppActivate($win.Id) } catch {}
        return
    }
    # a previous copy is stuck in the background (the old "restart the PC" case): offer to end it
    $a = [Windows.Forms.MessageBox]::Show(
        "Thunderbird Mail Fix ที่เปิดไว้ก่อนหน้ายังค้างอยู่เบื้องหลัง`r`n`r`nต้องการปิดตัวที่ค้างแล้วเปิดใหม่หรือไม่?",
        'Thunderbird Mail Fix', 'YesNo', 'Question')
    if ($a -ne 'Yes') { return }
    foreach ($o in $others) { Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    if (-not $mutex) { try { $mutex = New-Object Threading.Mutex($false, $mutexName) } catch { $mutex = $null } }
    if (-not $mutex -or -not (Get-SingleInstance 5000)) {
        [Windows.Forms.MessageBox]::Show(
            "ปิดตัวที่ค้างไม่ได้ (อาจเปิดไว้ด้วยสิทธิ์ Administrator)`r`n`r`nเปิด Task Manager แล้วปิด ThunderbirdMailFix / Windows PowerShell จากนั้นเปิดโปรแกรมใหม่",
            'Thunderbird Mail Fix', 'OK', 'Warning') | Out-Null
        return
    }
}

# Hide the black console window behind the GUI (script mode only; never fatal)
try {
    Add-Type -Name Win -Namespace Native -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    [Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0) | Out-Null
} catch {}

# ================================================================================
#  ENGINE  (runs in a background runspace so the window never freezes)
#    Mode 'scan' : find every account and test it
#    Mode 'fix'  : repair the accounts in $opt.Targets, then scan again
# ================================================================================
$engine = {
    param($sync, $opt)

    $backupDir  = $opt.BackupDir
    $logFile    = if ($backupDir) { Join-Path $backupDir 'fix-log.txt' }
    if ($backupDir) { New-Item -ItemType Directory -Force -Path $backupDir -ErrorAction SilentlyContinue | Out-Null }   # before the first log line
    $driveCache = @{}
    $RO_SYS     = [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::System

    function Log($level, $msg) {
        $sync.Queue.Enqueue(@($level, $msg))
        if ($logFile) { try { Add-Content -Path $logFile -Value "[$level] $msg" -Encoding UTF8 } catch {} }
    }
    function Prog($pct, $text) { $sync.Progress = [int]$pct; if ($text) { $sync.StatusText = $text } }
    function New-Issue($code, $text, $fixable) { @{ Code = $code; Text = $text; Fixable = $fixable } }
    function Join-Names($list) {
        $names = @($list | Select-Object -First 3 | ForEach-Object { $_.Name })
        ($names -join ', ') + $(if (@($list).Count -gt 3) { ', ...' })
    }

    function Move-ToBackup([string]$path, [string]$root) {
        $rel  = if ($root -and $path.StartsWith($root)) { $path.Substring($root.Length).TrimStart('\') } else { Split-Path $path -Leaf }
        $dest = Join-Path $backupDir $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
        try { Move-Item -LiteralPath $path -Destination $dest -Force -ErrorAction Stop; return $true }
        catch { Log 'WARN' "ย้ายไฟล์ไม่ได้ $path : $($_.Exception.Message)"; return $false }
    }

    # Every Thunderbird profile on the PC, with the SID of the Windows user who owns it
    function New-TbProfile($user, $userDir, $sid, $path, $root = $null) {
        [pscustomobject]@{
            User = $user; UserDir = $userDir; Path = (Resolve-Path -LiteralPath $path).Path; OwnerSid = $sid; Root = $root
            # who counts as "the user can write": owner, Everyone, Authenticated Users, Users
            Sids = @($sid, 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') }
    }

    # Sections of profiles.ini as hashtables (Name, Path, IsRelative, Default, ... + _Section, _Full)
    function Read-ProfilesIni($tbRoot) {
        $ini = Join-Path $tbRoot 'profiles.ini'
        $out = @()
        if (-not (Test-Path -LiteralPath $ini)) { return $out }
        $section = $null
        foreach ($line in @(Get-Content -LiteralPath $ini -ErrorAction SilentlyContinue) + '[end]') {
            if ($line -match '^\s*\[(.+)\]') {
                if ($section -and $section.Path) {
                    $p = [Environment]::ExpandEnvironmentVariables($section.Path.Trim()) -replace '/', '\'
                    $section._Full = if ($section.IsRelative -ne '0') { Join-Path $tbRoot $p } else { $p }
                }
                if ($section) { $out += $section }
                $section = @{ _Section = $Matches[1] }
            }
            elseif ($section -and $line -match '^\s*(\w+)\s*=(.*)$') { $section[$Matches[1]] = $Matches[2].Trim() }
        }
        $out
    }

    # Profile folders: everything listed in profiles.ini PLUS every <root>\Profiles\* folder with a
    # prefs.js - a profiles.ini that was rewritten can "forget" the profile that still holds all the mail
    function Get-ProfilePaths($tbRoot) {
        $paths = @(Read-ProfilesIni $tbRoot | Where-Object { $_._Full } | ForEach-Object { $_._Full }) +
                 @(Get-ChildItem -LiteralPath (Join-Path $tbRoot 'Profiles') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        @($paths | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'prefs.js') } |
            ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Sort-Object -Unique)
    }

    # The profile(s) Thunderbird actually opens: installs.ini / [Install...] in profiles.ini
    # (Thunderbird 67+), otherwise the profile marked Default=1
    function Get-DefaultProfilePaths($tbRoot) {
        $defs = @()
        $toFull = { param($v) $v = [Environment]::ExpandEnvironmentVariables($v.Trim()) -replace '/', '\'
                    [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($v)) { $v } else { Join-Path $tbRoot $v })).TrimEnd('\') }
        $inst = Join-Path $tbRoot 'installs.ini'
        if (Test-Path -LiteralPath $inst) {
            foreach ($line in Get-Content -LiteralPath $inst -ErrorAction SilentlyContinue) {
                if ($line -match '^\s*Default\s*=(.+)$') { $defs += & $toFull $Matches[1] }
            }
        }
        $sections = @(Read-ProfilesIni $tbRoot)
        foreach ($s in $sections | Where-Object { $_._Section -like 'Install*' -and $_.Default }) { $defs += & $toFull $s.Default }
        if (-not $defs) { $defs = @($sections | Where-Object { $_.Default -eq '1' -and $_._Full } | ForEach-Object { [IO.Path]::GetFullPath($_._Full).TrimEnd('\') }) }
        @($defs | Sort-Object -Unique)
    }

    # Point Thunderbird at the profile that has the mail: rewrite every default (installs.ini,
    # [Install...] sections, Default=1) and list the profile in profiles.ini if it was missing
    function Set-DefaultProfile($wd) {
        $root = $wd.Root.TrimEnd('\')
        $isRel = $wd.Target.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)
        $value = if ($isRel) { $wd.Target.Substring($root.Length + 1) -replace '\\', '/' } else { $wd.Target }
        $inst = Join-Path $root 'installs.ini'
        if (Test-Path -LiteralPath $inst) {
            Copy-Item -LiteralPath $inst (Join-Path $backupDir 'installs.ini.bak') -Force
            $lines = @(Get-Content -LiteralPath $inst | ForEach-Object { if ($_ -match '^\s*Default\s*=') { "Default=$value" } else { $_ } })
            [IO.File]::WriteAllLines($inst, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
        }
        $ini = Join-Path $root 'profiles.ini'
        if (Test-Path -LiteralPath $ini) { Copy-Item -LiteralPath $ini (Join-Path $backupDir 'profiles.ini.bak') -Force }
        $sections = @(Read-ProfilesIni $root)
        $hasInstall = [bool]($sections | Where-Object { $_._Section -like 'Install*' })
        $listed = [bool]($sections | Where-Object { $_._Full -and [IO.Path]::GetFullPath($_._Full).TrimEnd('\') -eq $wd.Target })
        $out = @(); $sec = ''
        foreach ($line in @(if (Test-Path -LiteralPath $ini) { Get-Content -LiteralPath $ini })) {
            if ($line -match '^\s*\[(.+)\]') { $sec = $Matches[1]; $out += $line; continue }
            if ($line -match '^\s*Default\s*=') {
                if ($sec -like 'Install*') { $out += "Default=$value" }
                elseif ($hasInstall) { $out += $line }   # Thunderbird 67+ ignores Default=1 when [Install] exists
                continue                                  # legacy: Default=1 is re-added below for the target only
            }
            $out += $line
            if (-not $hasInstall -and $sec -notlike 'Install*' -and $line -match '^\s*Path\s*=') {
                $s = $sections | Where-Object { $_._Section -eq $sec } | Select-Object -First 1
                if ($s -and $s._Full -and [IO.Path]::GetFullPath($s._Full).TrimEnd('\') -eq $wd.Target) { $out += 'Default=1' }
            }
        }
        if (-not $listed) {
            $n = 0; while ($sections | Where-Object { $_._Section -eq "Profile$n" }) { $n++ }
            $out += '', "[Profile$n]", "Name=$(Split-Path $wd.Target -Leaf)", "IsRelative=$(if ($isRel) { 1 } else { 0 })", "Path=$value"
            if (-not $hasInstall) { $out += 'Default=1' }
        }
        [IO.File]::WriteAllLines($ini, [string[]]$out, (New-Object Text.UTF8Encoding($false)))
        Log 'OK' "ตั้งให้ Thunderbird เปิดโปรไฟล์ $(Split-Path $wd.Target -Leaf) (โปรไฟล์ที่มีเมล) แล้ว - สำรองไฟล์ตั้งค่าเดิมไว้ในโฟลเดอร์สำรอง"
    }

    function Get-TbProfiles {
        $sidByPath = @{}
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue | ForEach-Object {
            $p = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
            # values like %SystemDrive%\Users\somchai must be expanded or Test-Path never finds them
            if ($p) { $sidByPath[[Environment]::ExpandEnvironmentVariables($p).ToLower()] = $_.PSChildName }
        }
        $mySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        # every Windows profile folder (ProfileList also finds profiles that are not on C:)
        $userDirs = if ($opt.IsAdmin) {
            @($sidByPath.Keys | Where-Object { Test-Path $_ } | ForEach-Object { Get-Item $_ }) +
            @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue) | Sort-Object FullName -Unique
        } else { @(Get-Item $env:USERPROFILE) }
        $found = @()
        foreach ($u in $userDirs) {
            $sid = $sidByPath[$u.FullName.ToLower()]
            if (-not $sid) { $sid = $mySid }
            # normal install + Microsoft Store install (keeps its AppData inside the app package)
            $roots = @(Join-Path $u.FullName 'AppData\Roaming\Thunderbird') +
                @(Get-ChildItem -LiteralPath (Join-Path $u.FullName 'AppData\Local\Packages') -Directory -Filter '*Thunderbird*' -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Thunderbird' })
            foreach ($tbRoot in $roots | Where-Object { Test-Path -LiteralPath $_ }) {
                foreach ($pp in Get-ProfilePaths $tbRoot) { $found += New-TbProfile $u.Name $u.FullName $sid $pp $tbRoot }
            }
        }
        # profiles the user picked by hand (Thunderbird Portable, profile on another drive...)
        foreach ($extra in @($opt.ExtraProfiles | Where-Object { $_ })) {
            if (Test-Path -LiteralPath (Join-Path $extra 'prefs.js')) { $found += New-TbProfile $env:USERNAME $env:USERPROFILE $mySid $extra }
        }
        @($found | Sort-Object Path -Unique)
    }

    function Read-Prefs($profilePath) {
        $h = @{}
        $file = Join-Path $profilePath 'prefs.js'
        if (-not (Test-Path $file)) { return $h }
        foreach ($line in Get-Content $file -Encoding UTF8) {
            if ($line -match '^user_pref\("([^"]+)",\s*(.*)\);\s*$') {
                $k = $Matches[1]; $v = $Matches[2].Trim()
                if ($v -match '^"(.*)"$') { $v = $Matches[1] -replace '\\\\', '\' -replace '\\"', '"' }
                $h[$k] = $v
            }
        }
        $h
    }

    # Mail accounts of one profile, read from prefs.js
    function Get-Accounts($pr) {
        $p = Read-Prefs $pr.Path
        # host names that have a saved password (logins.json stores "imap://host", "mailbox://host", "smtp://host")
        $saved = @()
        $lj = Join-Path $pr.Path 'logins.json'
        if (Test-Path $lj) {
            try { $saved = @((Get-Content $lj -Raw | ConvertFrom-Json).logins | ForEach-Object { $_.hostname.ToLower() }) } catch {}
        }
        $list = @()
        foreach ($a in @($p['mail.accountmanager.accounts'] -split ',' | Where-Object { $_ })) {
            $srv  = $p["mail.account.$a.server"]
            if (-not $srv) { continue }
            $type = $p["mail.server.$srv.type"]
            if ($type -notin 'imap', 'pop3', 'none', 'movemail') { continue }   # skip chat / RSS / news
            $ids   = $p["mail.account.$a.identities"]
            $id    = if ($ids) { ($ids -split ',')[0] }
            $email = if ($id) { $p["mail.identity.$id.useremail"] }
            if (-not $email) { $email = if ($type -eq 'none') { 'Local Folders' } else { "$($p["mail.server.$srv.userName"])" } }
            $dir = $p["mail.server.$srv.directory"]
            if (-not $dir -and $p["mail.server.$srv.directory-rel"]) {
                $dir = Join-Path $pr.Path (($p["mail.server.$srv.directory-rel"] -replace '^\[ProfD\]', '') -replace '/', '\')
            }
            $hostName = $p["mail.server.$srv.hostname"]
            $ssl  = $p["mail.server.$srv.socketType"] -eq '3'
            $port = $p["mail.server.$srv.port"]
            if (-not $port) { $port = @{ imap = $(if ($ssl) { 993 } else { 143 }); pop3 = $(if ($ssl) { 995 } else { 110 }) }[$type] }
            $smtpKey = if ($id) { $p["mail.identity.$id.smtpServer"] }
            if (-not $smtpKey) { $smtpKey = $p['mail.smtp.defaultserver'] }
            $smtpHost = if ($smtpKey) { $p["mail.smtpserver.$smtpKey.hostname"] }
            $smtpPort = if ($smtpKey) { $p["mail.smtpserver.$smtpKey.port"] }
            if ($smtpHost -and -not $smtpPort) { $smtpPort = if ($p["mail.smtpserver.$smtpKey.try_ssl"] -eq '3') { 465 } else { 587 } }
            $smtpUser   = if ($smtpKey) { $p["mail.smtpserver.$smtpKey.username"] }
            $smtpSocket = if ($smtpKey) { $p["mail.smtpserver.$smtpKey.try_ssl"] }
            $smtpAuth   = if ($smtpKey) { $p["mail.smtpserver.$smtpKey.authMethod"] }
            $scheme = @{ imap = 'imap'; pop3 = 'mailbox' }[$type]
            $list += [pscustomobject]@{
                Key = "$($pr.Path)|$srv"; ServerKey = $srv; RawType = $type; Email = $email; Server = $hostName
                Type = @{ imap = 'IMAP'; pop3 = 'POP3'; none = 'Local Folders'; movemail = 'Movemail' }[$type]
                Dir = $dir; Profile = $pr; Port = [int]$port; SmtpHost = $smtpHost; SmtpPort = [int]$smtpPort; Ssl = $ssl
                SmtpUser = $smtpUser; SmtpSocket = $smtpSocket; SmtpAuth = $smtpAuth
                UserName = $p["mail.server.$srv.userName"]; SocketType = $p["mail.server.$srv.socketType"]
                LeaveOnServer = ($p["mail.server.$srv.leave_on_server"] -eq 'true')
                GlobalInbox = [bool]$p["mail.server.$srv.deferred_to_account"]
                CheckNewOff = ($p["mail.server.$srv.check_new_mail"] -eq 'false')
                OAuth = ($p["mail.server.$srv.authMethod"] -eq '10')
                HasPassword = ($scheme -and $hostName -and ($saved -contains "${scheme}://$($hostName.ToLower())")) }
        }
        $list
    }

    # Network checks are cached per host:port so shared servers are only tested once
    $netCache = @{}
    function Test-Server($hostName, $port) {
        $k = "${hostName}:$port"
        if ($netCache.ContainsKey($k)) { return $netCache[$k] }
        $res = 'ok'
        try {   # DNS with a timeout - a broken DNS server must not freeze the scan
            $dns = [Net.Dns]::BeginGetHostAddresses($hostName, $null, $null)
            if ($dns.AsyncWaitHandle.WaitOne(5000)) { [void][Net.Dns]::EndGetHostAddresses($dns) } else { $res = 'dns' }
        } catch { $res = 'dns' }
        if ($res -eq 'ok') {
            $tcp = New-Object Net.Sockets.TcpClient
            try {
                $ar = $tcp.BeginConnect($hostName, $port, $null, $null)
                if (-not ($ar.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected)) { $res = 'port' }
            } catch { $res = 'port' } finally { $tcp.Close() }
        }
        $netCache[$k] = $res; $res
    }

    # Talks to a POP3 server like Thunderbird does: TLS handshake (port 995) + "+OK" greeting.
    # Returns 'ok', 'cert:<reason>', 'noreply' or 'port'. Certificate problems make Thunderbird refuse to download.
    $popCache = @{}
    function Test-Pop3($hostName, $port, $ssl) {
        $k = "${hostName}:$port"
        if ($popCache.ContainsKey($k)) { return $popCache[$k] }
        $res = 'noreply'
        $tcp = New-Object Net.Sockets.TcpClient
        try {
            $ar = $tcp.BeginConnect($hostName, $port, $null, $null)
            if (-not ($ar.AsyncWaitHandle.WaitOne(5000) -and $tcp.Connected)) { $res = 'port' }
            else {
                $tcp.ReceiveTimeout = 8000; $tcp.SendTimeout = 8000
                $stream = $tcp.GetStream()
                if ($ssl) {
                    $script:certErr = 'None'
                    $cb = [Net.Security.RemoteCertificateValidationCallback] { param($s, $cert, $chain, $err) $script:certErr = [string]$err; $true }
                    $tls = New-Object Net.Security.SslStream($stream, $false, $cb)
                    $tls.AuthenticateAsClient($hostName)
                    $stream = $tls
                }
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII)
                $greeting = $reader.ReadLine()
                if ($greeting -like '+OK*') {
                    $res = 'ok'
                    $w = New-Object IO.StreamWriter($stream, [Text.Encoding]::ASCII); $w.Write("QUIT`r`n"); $w.Flush()
                }
                if ($ssl -and $script:certErr -ne 'None') {
                    $res = 'cert:' + $(switch -Wildcard ($script:certErr) {
                        '*NameMismatch*' { 'ชื่อในใบรับรองไม่ตรงกับชื่อเซิร์ฟเวอร์' }
                        '*ChainErrors*'  { 'ใบรับรองหมดอายุหรือไม่น่าเชื่อถือ' }
                        default          { $script:certErr } })
                }
            }
        } catch { if ($res -ne 'port') { $res = 'noreply' } }
        finally { $tcp.Close() }
        $popCache[$k] = $res; $res
    }

    # Logs in to a POP3 server with the password the user typed (kept in memory only, never logged),
    # exactly like "Get Messages", and explains the server's answer.
    function Test-Pop3Login($L, $pw) {
        Log 'STEP' "ทดสอบรับเมล: $($L.UserName) @ $($L.Server):$($L.Port)"
        $result = @{ Ok = $false; Summary = ''; Text = '' }
        $tcp = New-Object Net.Sockets.TcpClient
        try {
            $ar = $tcp.BeginConnect($L.Server, $L.Port, $null, $null)
            if (-not ($ar.AsyncWaitHandle.WaitOne(8000) -and $tcp.Connected)) { throw 'CONNECT' }
            $tcp.ReceiveTimeout = 15000; $tcp.SendTimeout = 15000
            $stream = $tcp.GetStream()
            $open = {
                param($s)
                $script:popR = New-Object IO.StreamReader($s, [Text.Encoding]::ASCII)
                $script:popW = New-Object IO.StreamWriter($s, [Text.Encoding]::ASCII); $script:popW.NewLine = "`r`n"
            }
            if ($L.SocketType -eq '3') { $tls = New-Object Net.Security.SslStream($stream, $false, { $true }); $tls.AuthenticateAsClient($L.Server); $stream = $tls }
            & $open $stream
            $send = { param($cmd) $script:popW.WriteLine($cmd); $script:popW.Flush(); $script:popR.ReadLine() }
            $greet = $script:popR.ReadLine()
            if ($greet -notlike '+OK*') { throw "GREETING:$greet" }
            if ($L.SocketType -eq '2') {   # STARTTLS
                if ((& $send 'STLS') -notlike '+OK*') { throw 'STLS' }
                $tls = New-Object Net.Security.SslStream($stream, $false, { $true }); $tls.AuthenticateAsClient($L.Server); & $open $tls
            }
            $r = & $send "USER $($L.UserName)"
            if ($r -like '+OK*') { $r = & $send "PASS $pw" }
            $pw = $null
            if ($r -notlike '+OK*') { throw "LOGIN:$r" }
            $stat = & $send 'STAT'
            [void](& $send 'QUIT')
            $count = 0; $bytes = [int64]0
            if ($stat -match '^\+OK\s+(\d+)\s+(\d+)') { $count = [int]$Matches[1]; $bytes = [int64]$Matches[2] }
            $result.Ok = $true
            $result.Summary = "ล็อกอินสำเร็จ - บนเซิร์ฟเวอร์มีเมล $count ฉบับ ($([math]::Round($bytes / 1MB, 1)) MB)"
            Log 'OK' $result.Summary
            $result.Text = "✔ $($result.Summary)`r`n`r`n" + $(if ($count -gt 0) {
                "รหัสผ่านถูกต้องและเซิร์ฟเวอร์ใช้งานได้ ถ้า Thunderbird ยังกด Get Messages ไม่ได้:`r`n" +
                "1. รหัสผ่านที่ Thunderbird จำไว้อาจเป็นรหัสเก่า - Settings > Privacy & Security > Saved Passwords > ลบรายการ mailbox://$($L.Server) แล้วกด Get Messages ใส่รหัสใหม่`r`n" +
                "2. ตรวจว่า Thunderbird ไม่ได้อยู่ในโหมด Work Offline (File > Offline)`r`n" +
                "3. กด แก้ไขอัตโนมัติ เพื่อซ่อมไฟล์สถานะ POP3 / กล่องจดหมาย"
            } else {
                "บนเซิร์ฟเวอร์ไม่มีเมลรอดาวน์โหลด ถ้าลูกค้าส่งมาแล้วแต่ไม่มีบนเซิร์ฟเวอร์:`r`n" +
                "•  อาจมีเครื่องอื่น/มือถือดึงเมลไปก่อนแล้ว`r`n•  อาจตก Spam บนเซิร์ฟเวอร์ (ดูใน Webmail)`r`n•  เมลอาจส่งไม่ถึง - ขอให้ลูกค้าส่งเมลตีกลับ (bounce) มาให้ดู"
            })
        }
        catch {
            $err  = "$($_.Exception.Message)" -replace '^Exception calling .*?: ', ''
            $code = if ($err -match '^(CONNECT|GREETING|STLS|LOGIN)') { $Matches[1] } else { 'EX' }
            $serverSaid = if ($err -match '^(LOGIN|GREETING):(.*)$') { $Matches[2].Trim() } else { $err }
            $why = switch ($code) {
                'CONNECT'  { "เชื่อมต่อเซิร์ฟเวอร์ $($L.Server):$($L.Port) ไม่ได้ - ตรวจอินเทอร์เน็ต / Firewall / Antivirus" }
                'GREETING' { 'เซิร์ฟเวอร์ไม่ตอบแบบ POP3 - ตรวจพอร์ตและการเข้ารหัส (SSL) ใน Server Settings' }
                'STLS'     { 'เซิร์ฟเวอร์ไม่รองรับ STARTTLS - เปลี่ยน Connection security เป็น SSL/TLS พอร์ต 995' }
                'LOGIN'    {   # classify by what the server itself said
                    switch -Regex ($serverSaid) {
                        'IN-USE|lock|in use|busy' { 'กล่องเมลถูกเปิดใช้งานอยู่โดยเครื่องอื่น (POP3 ให้เข้าได้ทีละเครื่อง) - ปิด Thunderbird / Outlook / มือถือเครื่องอื่นที่ใช้บัญชีนี้ รอ 5-10 นาทีแล้วลองใหม่'; break }
                        'SYS|temp|quota|full'     { 'เซิร์ฟเวอร์เมลมีปัญหาชั่วคราวหรือพื้นที่เต็ม - ติดต่อผู้ดูแลเมลเซิร์ฟเวอร์'; break }
                        default                   { 'รหัสผ่านหรือชื่อผู้ใช้ไม่ถูกต้อง หรือบัญชีถูกระงับ - ตรวจรหัสผ่านกับผู้ดูแลเมลเซิร์ฟเวอร์ แล้วอัปเดตใน Thunderbird (Settings > Privacy & Security > Saved Passwords)' }
                    }
                }
                default {
                    if ($err -match 'timed out|time out|period of time') { 'เซิร์ฟเวอร์ไม่ตอบกลับภายในเวลาที่กำหนด - ลองใหม่อีกครั้ง หรือตรวจ Firewall' }
                    elseif ($err -match 'certificate|SSL|TLS|authentication') { 'เชื่อมต่อแบบเข้ารหัส (SSL) ไม่สำเร็จ - ตรวจ Connection security / พอร์ตใน Server Settings' }
                    else { 'เชื่อมต่อเซิร์ฟเวอร์ไม่สำเร็จ' }
                }
            }
            $result.Summary = "รับเมลไม่ได้ - $why"
            $result.Text = "✖ $why`r`n`r`nข้อความจากเซิร์ฟเวอร์: $serverSaid"
            Log 'ERR' "$why  (เซิร์ฟเวอร์ตอบ: $serverSaid)"
        }
        finally { $pw = $null; $tcp.Close() }
        $result
    }

    # Logs in to the outgoing (SMTP) server like "Send" does - EHLO, STARTTLS, AUTH - and quits
    # without sending anything. Same password as the incoming test (memory only, never logged).
    function Test-SmtpLogin($L, $pw) {
        Log 'STEP' "ทดสอบส่งเมล: $($L.SmtpHost):$($L.SmtpPort)"
        $user = if ($L.SmtpUser) { $L.SmtpUser } else { $L.UserName }
        $implicitTls = $L.SmtpSocket -eq '3' -or $L.SmtpPort -eq 465
        $result = @{ Ok = $false; Summary = ''; Text = '' }
        $tcp = New-Object Net.Sockets.TcpClient
        try {
            $ar = $tcp.BeginConnect($L.SmtpHost, $L.SmtpPort, $null, $null)
            if (-not ($ar.AsyncWaitHandle.WaitOne(8000) -and $tcp.Connected)) { throw 'CONNECT' }
            $tcp.ReceiveTimeout = 15000; $tcp.SendTimeout = 15000
            $raw = $tcp.GetStream()
            $open = {
                param($s)
                $script:smR = New-Object IO.StreamReader($s, [Text.Encoding]::ASCII)
                $script:smW = New-Object IO.StreamWriter($s, [Text.Encoding]::ASCII); $script:smW.NewLine = "`r`n"
            }
            # an SMTP reply can span lines: "250-..." continues, "250 ..." ends it
            $reply = { $lines = @(); do { $l = $script:smR.ReadLine(); if ($null -eq $l) { break }; $lines += $l } while ($l.Length -ge 4 -and $l[3] -eq '-'); , $lines }
            $send  = { param($cmd) $script:smW.WriteLine($cmd); $script:smW.Flush(); & $reply }
            if ($implicitTls) { $tls = New-Object Net.Security.SslStream($raw, $false, { $true }); $tls.AuthenticateAsClient($L.SmtpHost); & $open $tls }
            else { & $open $raw }
            $g = & $reply
            if (-not $g -or $g[-1] -notlike '220*') { throw "GREETING:$($g -join ' ')" }
            $ehlo = & $send 'EHLO tbfix.local'
            if (-not $ehlo -or $ehlo[-1] -notlike '250*') { throw "GREETING:$($ehlo -join ' ')" }
            if (-not $implicitTls -and ($ehlo -match 'STARTTLS')) {
                $st = & $send 'STARTTLS'
                if ($st[-1] -notlike '220*') { throw "TLS:$($st -join ' ')" }
                $tls = New-Object Net.Security.SslStream($raw, $false, { $true }); $tls.AuthenticateAsClient($L.SmtpHost); & $open $tls
                $ehlo = & $send 'EHLO tbfix.local'
            } elseif (-not $implicitTls -and $L.SmtpSocket -eq '2') { throw 'NOSTARTTLS' }

            if ($L.SmtpAuth -eq '1') {
                $result.Ok = $true; $result.Summary = 'เชื่อมต่อเซิร์ฟเวอร์ส่งเมลได้ (ตั้งค่าไว้ว่าไม่ต้องล็อกอิน)'
            } elseif ($L.SmtpAuth -eq '10') {
                $result.Ok = $true; $result.Summary = 'เชื่อมต่อเซิร์ฟเวอร์ส่งเมลได้ (ใช้ OAuth2 - ทดสอบรหัสผ่านแบบนี้ไม่ได้)'
            } else {
                $auth = ($ehlo | Where-Object { $_ -match 'AUTH[ =]' }) -join ' '
                $b64 = { param($t) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t)) }
                if ($auth -match 'PLAIN') { $a = & $send ('AUTH PLAIN ' + (& $b64 "`0$user`0$pw")) }
                elseif ($auth -match 'LOGIN') {
                    $a = & $send 'AUTH LOGIN'
                    if ($a[-1] -like '334*') { $a = & $send (& $b64 $user) }
                    if ($a[-1] -like '334*') { $a = & $send (& $b64 $pw) }
                } else { throw 'NOAUTH' }
                $pw = $null
                if ($a[-1] -notlike '235*') { throw "AUTH:$($a -join ' ')" }
                $result.Ok = $true; $result.Summary = 'ล็อกอินเซิร์ฟเวอร์ส่งเมลสำเร็จ - ส่งเมลได้'
            }
            [void](& $send 'QUIT')
            Log 'OK' $result.Summary
            $result.Text = "✔ $($result.Summary)`r`n$($L.SmtpHost):$($L.SmtpPort)  •  ผู้ใช้: $user"
        }
        catch {
            $err  = "$($_.Exception.Message)" -replace '^Exception calling .*?: ', ''
            $code = if ($err -match '^(CONNECT|GREETING|TLS|NOSTARTTLS|NOAUTH|AUTH)') { $Matches[1] } else { 'EX' }
            $serverSaid = if ($err -match '^(GREETING|TLS|AUTH):(.*)$') { $Matches[2].Trim() } else { $err }
            $why = switch ($code) {
                'CONNECT'    { "เชื่อมต่อเซิร์ฟเวอร์ส่งเมล $($L.SmtpHost):$($L.SmtpPort) ไม่ได้ - Firewall / Antivirus / ผู้ให้บริการเน็ตอาจบล็อกพอร์ตนี้ (ลองพอร์ต 587 หรือ 465)" }
                'GREETING'   { 'เซิร์ฟเวอร์ไม่ตอบแบบ SMTP - ตรวจพอร์ตและการเข้ารหัสของ Outgoing Server (SMTP)' }
                'TLS'        { 'เริ่มการเข้ารหัส STARTTLS ไม่สำเร็จ - ลองเปลี่ยน Connection security' }
                'NOSTARTTLS' { 'ตั้งค่าเป็น STARTTLS แต่เซิร์ฟเวอร์ไม่รองรับ - เปลี่ยน Connection security เป็น SSL/TLS พอร์ต 465' }
                'NOAUTH'     { 'เซิร์ฟเวอร์ไม่เปิดให้ล็อกอินที่พอร์ตนี้ - ลองพอร์ต 587 + STARTTLS หรือ 465 + SSL/TLS' }
                'AUTH'       {
                    if ($serverSaid -match '^53[05]|5\.7\.') {
                        if ($serverSaid -match '^530') { 'ต้องเข้ารหัสก่อนล็อกอิน - ตั้ง Connection security ของ SMTP เป็น STARTTLS หรือ SSL/TLS' }
                        else { "รหัสผ่านสำหรับส่งเมลไม่ถูกต้อง (ชื่อผู้ใช้ SMTP: $user) - แก้ที่ Settings > Outgoing Server (SMTP) และลบรหัสเก่าใน Saved Passwords" }
                    } elseif ($serverSaid -match '^4') { 'เซิร์ฟเวอร์ส่งเมลมีปัญหาชั่วคราว - ลองใหม่ภายหลัง' }
                    else { 'เซิร์ฟเวอร์ปฏิเสธการล็อกอินสำหรับส่งเมล' }
                }
                default {
                    if ($err -match 'timed out|time out|period of time') { 'เซิร์ฟเวอร์ส่งเมลไม่ตอบกลับภายในเวลาที่กำหนด - ตรวจ Firewall' }
                    elseif ($err -match 'certificate|SSL|TLS|authentication') { 'เชื่อมต่อแบบเข้ารหัส (SSL) กับเซิร์ฟเวอร์ส่งเมลไม่สำเร็จ - ตรวจ Connection security / พอร์ต' }
                    else { 'เชื่อมต่อเซิร์ฟเวอร์ส่งเมลไม่สำเร็จ' }
                }
            }
            $result.Summary = "ส่งเมลไม่ได้ - $why"
            $result.Text = "✖ $why`r`n`r`nข้อความจากเซิร์ฟเวอร์: $serverSaid"
            Log 'ERR' "$why  (เซิร์ฟเวอร์ตอบ: $serverSaid)"
        }
        finally { $pw = $null; $tcp.Close() }
        $result
    }

    # popstate.dat remembers which POP3 messages were already downloaded; when it is damaged
    # Thunderbird can skip new mail. Valid lines: comments, "*host user", "k|d|f|b <uidl> <time>".
    function Test-PopState($dir) {
        $f = Join-Path $dir 'popstate.dat'
        if (-not (Test-Path -LiteralPath $f)) { return $true }
        try { $lines = [IO.File]::ReadAllLines($f) } catch { return $false }
        if (-not $lines -or $lines[0] -notlike '# POP3 State File*') { return $false }
        foreach ($l in $lines) { if ($l -and $l -notmatch '^(#|\*\S+ |[kdfb] \S+ \d+)') { return $false } }
        $true
    }

    # Enabled message filters that delete mail, move it away or mark it as junk
    function Get-RiskyFilters($dir) {
        $f = Join-Path $dir 'msgFilterRules.dat'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        $filters = @(); $cur = $null
        foreach ($l in Get-Content -LiteralPath $f -Encoding UTF8 -ErrorAction SilentlyContinue) {
            if ($l -notmatch '^(\w+)="(.*)"$') { continue }
            $key = $Matches[1]; $val = $Matches[2]
            switch ($key) {
                'name'        { $cur = @{ Name = $val; Enabled = $false; Actions = @() }; $filters += $cur }
                'enabled'     { if ($cur) { $cur.Enabled = ($val -eq 'yes') } }
                'action'      { if ($cur) { $cur.Actions += @{ Type = $val; Value = '' } } }
                'actionValue' { if ($cur -and $cur.Actions) { $cur.Actions[-1].Value = $val } }
            }
        }
        foreach ($flt in $filters | Where-Object { $_.Enabled }) {
            $what = foreach ($a in $flt.Actions) {
                switch ($a.Type) {
                    'Delete'                 { 'ลบเมล' }
                    'Delete from Pop3 server' { 'ลบจากเซิร์ฟเวอร์' }
                    'JunkScore'              { if ($a.Value -eq '100') { 'ส่งเข้า Junk' } }
                    'Move to folder'         { 'ย้ายไป ' + [Uri]::UnescapeDataString(($a.Value -split '/')[-1]) }
                }
            }
            if ($what) { "$($flt.Name) ($(@($what) -join ', '))" }
        }
    }

    # Live (not deleted) messages that arrived in the last $days days. Only the end of the file
    # is read: new mail is appended, so big folders stay fast.
    function Get-RecentMailCount($file, $days) {
        $fi = Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
        if (-not $fi -or $fi.Length -eq 0 -or $fi.LastWriteTime -lt (Get-Date).AddDays(-$days)) { return 0 }
        $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
        try {
            [void]$fs.Seek([math]::Max(0, $fs.Length - 20MB), 'Begin')
            $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::GetEncoding(28591))).ReadToEnd()
        } finally { $fs.Close() }
        $since = (Get-Date).AddDays(-$days); $n = 0; $recent = $false; $dated = $false
        foreach ($m in [regex]::Matches($text, '(?m)^(?:From - (?<d>[^\r\n]+)|X-Mozilla-Status: (?<s>[0-9a-fA-F]{4}))')) {
            if ($m.Groups['d'].Success) {
                $when = [datetime]::MinValue
                $dated = [datetime]::TryParseExact(($m.Groups['d'].Value -replace '\s+', ' ').Trim(), 'ddd MMM d HH:mm:ss yyyy',
                    [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$when)
                $recent = (-not $dated) -or $when -ge $since
            } elseif ($recent -and -not ([Convert]::ToInt32($m.Groups['s'].Value, 16) -band 0x8)) { $n++; $recent = $false }
        }
        $n
    }

    # Messages waiting in Local Folders > Outbox ("Unsent Messages"), ignoring ones flagged deleted
    function Get-OutboxCount($dir) {
        $f = Join-Path $dir 'Unsent Messages'
        if (-not (Test-Path -LiteralPath $f) -or (Get-Item -LiteralPath $f).Length -eq 0) { return 0 }
        $n = 0
        foreach ($m in Select-String -LiteralPath $f -Pattern '^X-Mozilla-Status: ([0-9a-fA-F]{4})') {
            if (-not ([Convert]::ToInt32($m.Matches[0].Groups[1].Value, 16) -band 0x8)) { $n++ }
        }
        $n
    }

    # Rewrites prefs.js entries (Thunderbird must be closed, it rewrites the file on exit)
    function Set-Prefs($profilePath, [hashtable]$values) {
        $file = Join-Path $profilePath 'prefs.js'
        $bak  = Join-Path $backupDir "prefs-$(Split-Path $profilePath -Leaf).js.bak"
        if (-not (Test-Path $bak)) { Copy-Item $file $bak -Force }
        $lines = @(Get-Content $file -Encoding UTF8 | Where-Object {
            $l = $_; -not ($values.Keys | Where-Object { $l -like "user_pref(""$_"",*" }) })
        foreach ($k in $values.Keys) { $lines += "user_pref(""$k"", $($values[$k]));" }
        [IO.File]::WriteAllLines($file, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
    }

    function Test-OwnerWrite([string]$path, $sids) {
        try { $acl = Get-Acl -LiteralPath $path -ErrorAction Stop } catch { return $false }
        $allow = $false
        foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($sids -notcontains $r.IdentityReference.Value) { continue }
            if ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
            $bits = [int64]$r.FileSystemRights
            if (-not (($bits -band 0x2) -or ($bits -band 0x50000000))) { continue }   # WriteData / GenericWrite / GenericAll
            if ($r.AccessControlType -eq 'Deny') { return $false }
            $allow = $true
        }
        $allow
    }

    function Test-Account($acc, $tbRunning) {
        $issues = @(); $size = 0; $dir = $acc.Dir
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
            $issues += New-Issue 'DIR_MISSING' "ไม่พบโฟลเดอร์เก็บอีเมล: $dir  (ต้องตั้งค่า Local Directory ใหม่ใน Account Settings > Server Settings)" $false
        } else {
            $items = @(Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue)
            $files = @($items | Where-Object { -not $_.PSIsContainer })
            $size  = [int64]($files | Measure-Object Length -Sum).Sum
            $mbox  = @($files | Where-Object { $_.Extension -eq '' -and $_.Name -notlike 'nstmp*' })

            $ro = @($files | Where-Object { $_.Attributes -band $RO_SYS })
            if ($ro) { $issues += New-Issue 'READONLY' "ไฟล์ถูกตั้งเป็น Read-only: $($ro.Count) ไฟล์ ($(Join-Names $ro))" $true }

            $nst = @($files | Where-Object { $_.Name -like 'nstmp*' })
            if ($nst) { $issues += New-Issue 'NSTMP' "ไฟล์ค้างจากการ Compact ที่ล้มเหลว: $($nst.Count) ไฟล์" $true }

            $badMsf = @($files | Where-Object { $_.Extension -eq '.msf' -and $_.Length -eq 0 } | Where-Object {
                $m = $_.FullName -replace '\.msf$', ''
                (Test-Path -LiteralPath $m) -and (Get-Item -LiteralPath $m -Force).Length -gt 0 })
            if ($badMsf) { $issues += New-Issue 'MSF' "ไฟล์ดัชนีโฟลเดอร์เสีย (.msf): $($badMsf.Count) ไฟล์ ($(Join-Names $badMsf))" $true }

            $check   = @(Get-Item -LiteralPath $dir -Force) + @($items | Select-Object -First 3000)
            $noWrite = @($check | Where-Object { -not (Test-OwnerWrite $_.FullName $acc.Profile.Sids) })
            if ($noWrite) { $issues += New-Issue 'NOWRITE' "ผู้ใช้ $($acc.Profile.User) ไม่มีสิทธิ์เขียน: $($noWrite.Count) รายการ ($(Join-Names $noWrite))" $true }

            try {
                $t = Join-Path $dir "tbfix-$([guid]::NewGuid().ToString('N')).tmp"
                [IO.File]::WriteAllText($t, 'x'); Remove-Item -LiteralPath $t -Force
            } catch { $issues += New-Issue 'WRITEFAIL' 'สร้างไฟล์ในโฟลเดอร์อีเมลไม่ได้ (ไม่มีสิทธิ์หรือถูกล็อก)' $true }

            if (-not $tbRunning) {
                $locked = @()
                foreach ($f in $mbox) {
                    try { $fs = [IO.File]::Open($f.FullName, 'Open', 'ReadWrite', 'ReadWrite'); $fs.Close() }
                    catch { $locked += $f }
                }
                if ($locked) {
                    $by = @(Get-FileLockers @($locked | ForEach-Object { $_.FullName }) | ForEach-Object { $_.Name } | Sort-Object -Unique)
                    $issues += New-Issue 'LOCKED' ("กล่องจดหมายเปิดเขียนไม่ได้ (ถูกล็อก/ไม่มีสิทธิ์): $($locked.Count) ไฟล์ ($(Join-Names $locked))" +
                        $(if ($by) { " - ถูกเปิดค้างโดยโปรแกรม: $($by -join ', ')" })) $true
                }
            }

            foreach ($b in @($mbox | Where-Object { $_.Length -gt 4GB })) {
                $issues += New-Issue 'BIG' "กล่องจดหมาย '$($b.Name)' ใหญ่ $([math]::Round($b.Length / 1GB, 1)) GB - ควร Compact และย้ายอีเมลเก่าไป Archive" $false
            }
        }

        # Thunderbird opens another (empty / missing) profile instead of this one
        $wd = $wrongDefault[$acc.Profile.Path]
        if ($wd) {
            $issues += New-Issue 'PROFILE_DEFAULT' ("Thunderbird เปิดโปรไฟล์ $(Split-Path $wd.Current -Leaf) " +
                $(if ($wd.CurrentExists) { '(ไม่มีบัญชีเมล)' } else { '(ไม่มีอยู่จริง)' }) +
                ' แทนโปรไฟล์นี้ - เปิด Thunderbird แล้วจะเห็นเหมือนเมลหายหมด (เมลยังอยู่ครบ) กดแก้ไขอัตโนมัติเพื่อตั้งให้เปิดโปรไฟล์นี้') $true
        }
        # crashes in the last week, and the add-ons that may cause them
        $crashes = $crashByRoot[[string]$acc.Profile.Root]
        if ($crashes) {
            $addons = @($addonsByProfile[$acc.Profile.Path])
            $issues += New-Issue 'CRASH' ("Thunderbird ปิดตัวเอง (crash) $crashes ครั้งใน 7 วันล่าสุด" + $(if ($addons) {
                " - มี Add-on เปิดอยู่ $($addons.Count) ตัว ($(($addons | Select-Object -First 3) -join ', ')) ลองกด เปิด Thunderbird > เปิดแบบไม่โหลด Add-on"
            } else { ' - ลองกด Optimize' })) $false
        }

        # Thunderbird stuck in the background on this profile
        foreach ($s in @($stuckList | Where-Object { $_.Profile -eq $acc.Profile.Path })) {
            $issues += New-Issue 'TB_STUCK' "Thunderbird ค้างอยู่เบื้องหลัง ($($s.Why), PID $($s.Id)) - ทำให้เปิด Thunderbird ไม่ขึ้น / รับเมลไม่ได้ กดแก้ไขอัตโนมัติเพื่อปิดให้ (ไม่ต้องรีสตาร์ทเครื่อง)" $true
        }

        # Receiving / sending: settings and network
        if ($acc.CheckNewOff) {
            $issues += New-Issue 'NOCHECK' 'ปิดการตรวจเมลใหม่อัตโนมัติไว้ (เมลจะไม่เข้าเอง)' $true
        }
        $inOk = $false
        if ($acc.Server -and $acc.Port) {
            switch (Test-Server $acc.Server $acc.Port) {
                'dns'  { $issues += New-Issue 'NET_IN' "หาเซิร์ฟเวอร์รับเมล $($acc.Server) ไม่เจอ (DNS) - ตรวจอินเทอร์เน็ต / ชื่อเซิร์ฟเวอร์" $false }
                'port' { $issues += New-Issue 'NET_IN' "เชื่อมต่อเซิร์ฟเวอร์รับเมล $($acc.Server):$($acc.Port) ไม่ได้ - ตรวจอินเทอร์เน็ต / Firewall / Antivirus" $false }
                'ok'   { $inOk = $true }
            }
        }

        # POP3: how mail is fetched and where it ends up
        if ($acc.RawType -eq 'pop3') {
            if ($inOk) {
                $pop = Test-Pop3 $acc.Server $acc.Port $acc.Ssl
                if ($pop -like 'cert:*') {
                    $issues += New-Issue 'POP_CERT' "ใบรับรอง SSL ของเซิร์ฟเวอร์ $($acc.Server) มีปัญหา: $($pop.Substring(5)) - Thunderbird อาจปฏิเสธการรับเมล (ตรวจที่ Settings > Certificates หรือติดต่อผู้ดูแลเมลเซิร์ฟเวอร์)" $false
                } elseif ($pop -ne 'ok') {
                    $issues += New-Issue 'POP_REPLY' "เซิร์ฟเวอร์ $($acc.Server):$($acc.Port) ไม่ตอบแบบ POP3 - ตรวจพอร์ต / การเข้ารหัส (SSL) ใน Server Settings" $false
                }
            }
            if ($dir -and (Test-Path -LiteralPath $dir) -and -not (Test-PopState $dir)) {
                $issues += New-Issue 'POPSTATE' 'ไฟล์สถานะ POP3 (popstate.dat) เสีย - Thunderbird อาจข้ามเมลใหม่ไม่ดาวน์โหลด' $true
            }
            if (-not $acc.LeaveOnServer) {
                $issues += New-Issue 'POP_LEAVE' 'POP3 ลบเมลออกจากเซิร์ฟเวอร์หลังดาวน์โหลด - ถ้ามีเครื่องอื่น/มือถือใช้บัญชีนี้ด้วย เครื่องที่ดึงก่อนจะได้เมลไปเครื่องเดียว (ติ๊ก "Leave messages on server" ทุกเครื่อง)' $false
            }
            if ($acc.GlobalInbox) {
                $issues += New-Issue 'GLOBAL_INBOX' 'เมลของบัญชีนี้ถูกเก็บรวมไว้ที่ Local Folders > Inbox (Global Inbox) - ให้หาเมลที่นั่น' $false
            }
        }

        # Mail that arrived but is not in the Inbox: filters and Junk
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            $risky = @(Get-RiskyFilters $dir)
            if ($risky) {
                $issues += New-Issue 'FILTER' "มี Filter ที่ย้าย/ลบเมลอัตโนมัติ $($risky.Count) กฎ: $(($risky | Select-Object -First 3) -join ', ')$(if ($risky.Count -gt 3) { ', ...' }) - ตรวจที่ Tools > Message Filters" $false
            }
            foreach ($jf in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -in 'Junk', 'Spam' })) {
                $nJunk = Get-RecentMailCount $jf.FullName 14
                if ($nJunk) {
                    $issues += New-Issue 'JUNK' "มีเมล $nJunk ฉบับเข้าโฟลเดอร์ $($jf.Name) ใน 14 วันล่าสุด - เมลลูกค้าอาจอยู่ในนี้ (คลิกขวาที่เมล > Mark > As Not Junk)" $false
                }
            }
        }
        if ($acc.SmtpHost -and $acc.SmtpPort) {
            switch (Test-Server $acc.SmtpHost $acc.SmtpPort) {
                'dns'  { $issues += New-Issue 'NET_OUT' "หาเซิร์ฟเวอร์ส่งเมล $($acc.SmtpHost) ไม่เจอ (DNS) - ส่งเมลไม่ออก" $false }
                'port' { $issues += New-Issue 'NET_OUT' "เชื่อมต่อเซิร์ฟเวอร์ส่งเมล $($acc.SmtpHost):$($acc.SmtpPort) ไม่ได้ - ส่งเมลไม่ออก (ตรวจ Firewall / Antivirus)" $false }
            }
        }
        if ($acc.RawType -in 'imap', 'pop3' -and -not $acc.OAuth -and -not $acc.HasPassword) {
            $issues += New-Issue 'NOPASS' 'ไม่ได้บันทึกรหัสผ่านไว้ - Thunderbird จะถามรหัสผ่านทุกครั้ง (ถ้ารหัสผิด เมลจะไม่เข้า)' $false
        }
        if ($acc.RawType -eq 'none' -and $dir -and (Test-Path -LiteralPath $dir)) {
            $out = Get-OutboxCount $dir
            if ($out) { $issues += New-Issue 'OUTBOX' "มีเมลค้างในกล่องขาออก (Outbox) $out ฉบับ - เปิด Thunderbird แล้วกด File > Send Unsent Messages" $false }
        }

        # Environment: disk space / file system / cloud sync
        $root = if ($dir) { $dir } else { $acc.Profile.Path }
        $l = $root.Substring(0, 1)
        if (-not $driveCache.ContainsKey($l)) { $driveCache[$l] = Get-Volume -DriveLetter $l -ErrorAction SilentlyContinue }
        $vol = $driveCache[$l]
        if ($vol) {
            $free = [math]::Round($vol.SizeRemaining / 1GB, 1)
            if ($free -lt 2) { $issues += New-Issue 'DISK' "ไดรฟ์ ${l}: เหลือพื้นที่ $free GB - ต้องเคลียร์พื้นที่ดิสก์" $false }
            if ($vol.FileSystem -eq 'FAT32') { $issues += New-Issue 'FAT32' "ไดรฟ์ ${l}: เป็น FAT32 (ไฟล์เกิน 4 GB ไม่ได้)" $false }
        }
        if ($root -match 'OneDrive|Dropbox|Google Drive') { $issues += New-Issue 'SYNC' 'โฟลเดอร์อยู่ใน OneDrive/Cloud sync ซึ่งอาจล็อกไฟล์อีเมล' $false }

        # red = mail cannot be written / received / sent; amber = worth checking
        $status = if (@($issues | Where-Object { $_.Fixable -or $_.Code -in 'DIR_MISSING', 'NET_IN', 'NET_OUT', 'DISK' }).Count) { 'problem' }
                  elseif ($issues.Count) { 'warn' } else { 'ok' }
        [pscustomobject]@{
            Key = $acc.Key; Email = $acc.Email; Type = $acc.Type; Server = $acc.Server; Dir = $dir
            RawType = $acc.RawType; Port = $acc.Port; SocketType = $acc.SocketType; UserName = $acc.UserName
            SmtpHost = $acc.SmtpHost; SmtpPort = $acc.SmtpPort; SmtpUser = $acc.SmtpUser; SmtpSocket = $acc.SmtpSocket; SmtpAuth = $acc.SmtpAuth
            User = $acc.Profile.User; ProfilePath = $acc.Profile.Path; Size = $size; Issues = $issues; Status = $status }
    }

    function Repair-Account($acc) {
        Log 'STEP' "กำลังแก้ไข: $($acc.Email)"
        $wd = $wrongDefault[$acc.Profile.Path]
        if ($wd -and -not $defaultFixed[$wd.Root]) {
            try { Set-DefaultProfile $wd; $defaultFixed[$wd.Root] = $true }
            catch { Log 'WARN' "ตั้งค่าโปรไฟล์เริ่มต้นไม่ได้: $($_.Exception.Message) - เปิด Thunderbird > เลือกโปรไฟล์ (Profile Manager) แล้วเลือกเอง" }
        }
        if ($acc.CheckNewOff) {
            try {
                Set-Prefs $acc.Profile.Path @{ "mail.server.$($acc.ServerKey).check_new_mail" = 'true'; "mail.server.$($acc.ServerKey).login_at_startup" = 'true' }
                Log 'OK' 'เปิดการตรวจเมลใหม่อัตโนมัติแล้ว'
            } catch { Log 'WARN' "แก้ค่าตรวจเมลใหม่ไม่ได้: $($_.Exception.Message)" }
        }
        $dir = $acc.Dir
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
            Log 'WARN' "ไม่พบโฟลเดอร์ $dir - แก้อัตโนมัติไม่ได้ ให้ตั้งค่า Local Directory ใหม่ใน Account Settings > Server Settings"
            return
        }
        if ($acc.RawType -eq 'pop3' -and -not (Test-PopState $dir)) {
            if (Move-ToBackup (Join-Path $dir 'popstate.dat') $acc.Profile.Path) {
                Log 'OK' "รีเซ็ตไฟล์สถานะ POP3 (popstate.dat) แล้ว$(if ($acc.LeaveOnServer) { ' - ครั้งแรกอาจดาวน์โหลดเมลที่ค้างบนเซิร์ฟเวอร์ซ้ำ' })"
            }
        }
        $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)

        $n = 0
        foreach ($f in @($files | Where-Object { $_.Name -like 'nstmp*' })) { if (Move-ToBackup $f.FullName $acc.Profile.Path) { $n++ } }
        if ($n) { Log 'OK' "ย้ายไฟล์ค้าง (nstmp) ไปโฟลเดอร์สำรอง $n ไฟล์" }

        $n = 0
        foreach ($f in $files) {
            if ((Test-Path -LiteralPath $f.FullName) -and ($f.Attributes -band $RO_SYS)) { try { $f.Attributes = 'Archive'; $n++ } catch {} }
        }
        if ($n) { Log 'OK' "ปลด Read-only $n ไฟล์" }

        $msf = if ($opt.RebuildIndex) { @($files | Where-Object { $_.Extension -eq '.msf' }) }
               else { @($files | Where-Object { $_.Extension -eq '.msf' -and $_.Length -eq 0 }) }
        $n = 0
        foreach ($f in $msf) { if (Move-ToBackup $f.FullName $acc.Profile.Path) { $n++ } }
        if ($n) { Log 'OK' "ย้ายไฟล์ดัชนี .msf $n ไฟล์ (Thunderbird จะสร้างใหม่เอง)" }

        $sid  = $acc.Profile.OwnerSid
        $name = try { (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value } catch { $null }
        Log 'INFO' "กำลังรีเซ็ตสิทธิ์โฟลเดอร์ให้ $(if ($name) { $name } else { $sid }) ..."
        if ($opt.IsAdmin) { & takeown.exe /F "$dir" /R /D Y 2>&1 | Out-Null }
        & icacls.exe "$dir" /reset /T /C /Q 2>&1 | Out-Null
        $r = & icacls.exe "$dir" /grant "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>&1
        $code = $LASTEXITCODE
        if ($opt.IsAdmin -and $name) { & icacls.exe "$dir" /setowner "$name" /T /C /Q 2>&1 | Out-Null }
        if ($code -eq 0) { Log 'OK' 'รีเซ็ตสิทธิ์ Full Control เรียบร้อย' } else { Log 'WARN' "รีเซ็ตสิทธิ์ไม่สำเร็จบางไฟล์: $r" }

        # mail files another program still holds open: end a leftover Thunderbird, name anything else
        $held = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension -eq '' -and $(try { [IO.File]::Open($_.FullName, 'Open', 'ReadWrite', 'ReadWrite').Close(); $false } catch { $true }) })
        if ($held) {
            foreach ($l in Get-FileLockers @($held | ForEach-Object { $_.FullName })) {
                if ($l.Name -eq 'thunderbird') { Stop-Process -Id $l.Id -Force -ErrorAction SilentlyContinue; Log 'OK' "ปิด Thunderbird ที่ค้างไฟล์อยู่ (PID $($l.Id))" }
                else { Log 'WARN' "ไฟล์เมลถูกโปรแกรม $($l.Name) เปิดค้างอยู่ - ปิดโปรแกรมนั้น หรือรอสักครู่แล้วสแกนใหม่ (ไม่ต้องรีสตาร์ทเครื่อง)" }
            }
        }
    }

    # Closes Thunderbird cleanly (it saves its files on exit); forces it only after 15 s.
    # A Thunderbird that is stuck in the background (no window / not responding) is ended at once.
    function Stop-Thunderbird {
        foreach ($s in @($stuckList)) {
            if ($s.Id) {
                Stop-Process -Id $s.Id -Force -ErrorAction SilentlyContinue
                Log 'OK' "ปิด Thunderbird ที่ค้างอยู่เบื้องหลัง (PID $($s.Id)) - ไม่ต้องรีสตาร์ทเครื่อง"
            }
        }
        if ($stuckList) { Start-Sleep -Milliseconds 800 }
        if (-not (Get-Process thunderbird -ErrorAction SilentlyContinue)) { return $true }
        $sync.StatusText = 'กำลังปิด Thunderbird...'
        Get-Process thunderbird -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        for ($i = 0; $i -lt 30 -and (Get-Process thunderbird -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
        if (Get-Process thunderbird -ErrorAction SilentlyContinue) {
            Log 'WARN' 'Thunderbird ไม่ปิดเองภายใน 15 วินาที - บังคับปิด'
            Get-Process thunderbird -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        if (Get-Process thunderbird -ErrorAction SilentlyContinue) {
            Log 'ERR' 'ปิด Thunderbird ไม่ได้ - กรุณาปิดเองแล้วลองใหม่ (ยังไม่ได้แก้ไขอะไร)'
            return $false
        }
        Log 'OK' 'ปิด Thunderbird แล้ว'
        $true
    }

    # --- Who is holding a file? (Windows Restart Manager - the same API the installer uses) ---
    function Get-FileLockers([string[]]$files) {
        if (-not $files) { return @() }
        if (-not ('TbFix.RM' -as [type])) {
            try {
                Add-Type -ErrorAction Stop -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
namespace TbFix {
public static class RM {
    [StructLayout(LayoutKind.Sequential)] struct UniqueProcess { public int Pid; public System.Runtime.InteropServices.ComTypes.FILETIME Start; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct ProcessInfo {
        public UniqueProcess Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string AppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string ServiceName;
        public int AppType; public uint Status; public uint Session; [MarshalAs(UnmanagedType.Bool)] public bool Restartable; }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint h, int flags, string key);
    [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint h);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint h, uint nFiles, string[] files, uint nApps, UniqueProcess[] apps, uint nSvc, string[] svc);
    [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint h, out uint needed, ref uint count, [In, Out] ProcessInfo[] info, ref uint reasons);
    public static int[] Lockers(string[] files) {
        var list = new List<int>(); uint h;
        if (RmStartSession(out h, 0, Guid.NewGuid().ToString()) != 0) return list.ToArray();
        try {
            if (RmRegisterResources(h, (uint)files.Length, files, 0, null, 0, null) != 0) return list.ToArray();
            uint needed, count = 0, reasons = 0;
            if (RmGetList(h, out needed, ref count, null, ref reasons) == 234 && needed > 0) {
                var info = new ProcessInfo[needed]; count = needed;
                if (RmGetList(h, out needed, ref count, info, ref reasons) == 0)
                    for (int i = 0; i < count; i++) list.Add(info[i].Process.Pid);
            }
        } finally { RmEndSession(h); }
        return list.ToArray();
    }
}}
'@
            } catch { return @() }
        }
        @([TbFix.RM]::Lockers($files) | Sort-Object -Unique | ForEach-Object {
            $p = Get-Process -Id $_ -ErrorAction SilentlyContinue
            [pscustomobject]@{ Id = $_; Name = $(if ($p) { $p.ProcessName } else { "PID $_" }); Proc = $p }
        })
    }

    # A Thunderbird that holds the profile lock but has no window or does not respond - the case
    # that used to need a restart ("Thunderbird is already running", Get Messages does nothing).
    function Get-StuckThunderbird($profiles) {
        $mySession = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $stuck = @()
        foreach ($pr in $profiles) {
            $lock = Join-Path $pr.Path 'parent.lock'
            if (-not (Test-Path -LiteralPath $lock)) { continue }
            try { $fs = [IO.File]::Open($lock, 'Open', 'ReadWrite', 'None'); $fs.Close(); continue } catch {}   # not held: fine
            $tray = (Read-Prefs $pr.Path)['mail.minimizeToTray'] -eq 'true'   # minimized to tray = no window, but not stuck
            foreach ($l in Get-FileLockers @($lock)) {
                $p = $l.Proc
                if ($p -and $p.SessionId -ne $mySession) { continue }   # another signed-in user's Thunderbird
                $noWindow = $p -and $p.MainWindowHandle -eq [IntPtr]::Zero -and -not $tray -and $p.StartTime -lt (Get-Date).AddSeconds(-60)
                $hung = $p -and $p.MainWindowHandle -ne [IntPtr]::Zero -and -not $p.Responding
                if ($noWindow -or $hung) {
                    $stuck += [pscustomobject]@{ Profile = $pr.Path; Id = $l.Id; Name = $l.Name; Why = $(if ($hung) { 'ไม่ตอบสนอง' } else { 'ไม่มีหน้าต่าง' }) }
                }
            }
        }
        $stuck
    }

    # "All my mail is gone": Thunderbird opens an empty (or missing) profile while the mail sits in
    # another profile of the same Thunderbird folder. Returns profile path -> what to switch.
    function Get-WrongDefaults($profiles, $accounts) {
        $map = @{}
        foreach ($grp in @($profiles | Where-Object { $_.Root }) | Group-Object Root) {
            $withMail = @($grp.Group | Where-Object { $p = $_.Path; @($accounts | Where-Object { $_.Profile.Path -eq $p -and $_.RawType -ne 'none' }).Count })
            if (-not $withMail) { continue }
            $defaults = @(Get-DefaultProfilePaths $grp.Name)
            if (-not $defaults) { continue }
            if ($withMail | Where-Object { $defaults -contains $_.Path.TrimEnd('\') }) { continue }   # opens a profile that has mail: fine
            $best = $withMail | Sort-Object -Descending {
                (Get-ChildItem -LiteralPath (Join-Path $_.Path 'Mail'), (Join-Path $_.Path 'ImapMail') -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            } | Select-Object -First 1
            $map[$best.Path] = [pscustomobject]@{ Root = $grp.Name; Current = $defaults[0]; CurrentExists = (Test-Path -LiteralPath $defaults[0]); Target = $best.Path.TrimEnd('\') }
        }
        $map
    }

    # Crash reports from the last 7 days (per Thunderbird folder) and the add-ons each profile loads
    function Get-CrashCount($tbRoot) {
        if (-not $tbRoot) { return 0 }
        @(Get-ChildItem -LiteralPath (Join-Path $tbRoot 'Crash Reports\pending') -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) }).Count
    }
    function Get-ActiveAddons($profilePath) {
        $f = Join-Path $profilePath 'extensions.json'
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        try { $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
        # user-installed add-ons live in "app-profile"; skip only Thunderbird's own (app-builtin / app-system-*)
        @($j.addons | Where-Object { $_.type -eq 'extension' -and $_.active -and $_.location -notmatch '^app-(builtin|system)' } |
            ForEach-Object { if ($_.defaultLocale.name) { $_.defaultLocale.name } else { $_.id } })
    }

    function Remove-Locks($pr) {
        foreach ($lock in 'parent.lock', 'lock', '.parentlock') {
            $lp = Join-Path $pr.Path $lock
            if (Test-Path $lp) { Remove-Item $lp -Force -ErrorAction SilentlyContinue; Log 'OK' "ลบไฟล์ล็อกโปรไฟล์: $lp" }
        }
    }

    function Clear-TbTemp($profs) {
        $n = 0
        $tempDirs = @($env:TEMP) + @($profs | ForEach-Object { Join-Path $_.UserDir 'AppData\Local\Temp' }) | Sort-Object -Unique
        foreach ($t in $tempDirs) {
            Get-ChildItem -Path $t -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^(nsmail|nscopy|nsemail|nsma|nsmime|nscpmsg)' } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue; $n++ }
        }
        Log 'OK' "ล้างไฟล์ชั่วคราวของ Thunderbird $n ไฟล์"
    }

    # --- SQLite through winsqlite3.dll (built into Windows 10/11) ---------------
    function Initialize-Sqlite {
        if (-not (Test-Path "$env:SystemRoot\System32\winsqlite3.dll")) { return $false }
        if (-not ('TbFix.Sqlite' -as [type])) {
            try {
            Add-Type -Namespace TbFix -Name Sqlite -ErrorAction Stop -MemberDefinition @'
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open16", CharSet = CharSet.Unicode)] public static extern int Open(string file, out IntPtr db);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close_v2")] public static extern int Close(IntPtr db);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_busy_timeout")] public static extern int BusyTimeout(IntPtr db, int ms);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare16_v2", CharSet = CharSet.Unicode)] public static extern int Prepare(IntPtr db, string sql, int bytes, out IntPtr stmt, IntPtr tail);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step")] public static extern int Step(IntPtr stmt);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_text16")] public static extern IntPtr ColumnText(IntPtr stmt, int col);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize")] public static extern int Finalize(IntPtr stmt);
'@
            } catch { return $false }   # compiler blocked (antivirus / AppLocker): skip the database step
        }
        $true
    }

    # Runs one statement; returns the first column of all rows joined, or "error <code>"
    function Invoke-Sqlite([string]$file, [string]$sql) {
        $db = [IntPtr]::Zero
        if ([TbFix.Sqlite]::Open($file, [ref]$db) -ne 0) { if ($db -ne [IntPtr]::Zero) { [void][TbFix.Sqlite]::Close($db) }; return 'error open' }
        try {
            [void][TbFix.Sqlite]::BusyTimeout($db, 5000)
            $stmt = [IntPtr]::Zero
            $rc = [TbFix.Sqlite]::Prepare($db, $sql, -1, [ref]$stmt, [IntPtr]::Zero)
            if ($rc -ne 0) { return "error $rc" }
            $rows = @()
            while (($rc = [TbFix.Sqlite]::Step($stmt)) -eq 100) {
                $rows += [Runtime.InteropServices.Marshal]::PtrToStringUni([TbFix.Sqlite]::ColumnText($stmt, 0))
            }
            [void][TbFix.Sqlite]::Finalize($stmt)
            if ($rc -ne 101) { return "error $rc" }
            $rows -join '; '
        } finally { [void][TbFix.Sqlite]::Close($db) }
    }

    # Files Thunderbird simply recreates when they are missing - safe to move away when broken
    $rebuildableDb   = 'global-messages-db.sqlite', 'favicons.sqlite', 'places.sqlite', 'formhistory.sqlite', 'content-prefs.sqlite',
                       'permissions.sqlite', 'webappsstore.sqlite', 'storage.sqlite', 'cookies.sqlite', 'bounce-tracking-protection.sqlite', 'cache.sqlite'
    $rebuildableJson = 'xulstore.json', 'folderCache.json', 'folderTree.json', 'session.json', 'sessionCheckpoints.json', 'times.json', 'handlers.json'

    function Optimize-Profile($pr, $profAccounts) {
        Log 'STEP' "Optimize โปรไฟล์ $(Split-Path $pr.Path -Leaf) ($($pr.User))"
        Remove-Locks $pr

        # 1. caches
        $local = Join-Path $pr.UserDir "AppData\Local\Thunderbird\Profiles\$(Split-Path $pr.Path -Leaf)"
        foreach ($cacheDir in @((Join-Path $pr.Path 'startupCache'), (Join-Path $local 'cache2'), (Join-Path $local 'startupCache'))) {
            if (Test-Path $cacheDir) { Remove-Item $cacheDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        Log 'OK' 'ล้างแคชของ Thunderbird แล้ว'

        # 2. databases: integrity check, then VACUUM
        if (Initialize-Sqlite) {
            $dbs = @(Get-ChildItem $pr.Path -Filter '*.sqlite' -File -ErrorAction SilentlyContinue) +
                   @(Get-ChildItem (Join-Path $pr.Path 'calendar-data') -Filter '*.sqlite' -File -ErrorAction SilentlyContinue)
            $saved = [int64]0; $okCount = 0
            foreach ($db in $dbs) {
                $check = Invoke-Sqlite $db.FullName 'PRAGMA quick_check;'
                if ($check -ne 'ok') {
                    if ($rebuildableDb -contains $db.Name) {
                        foreach ($f in @($db.FullName, "$($db.FullName)-wal", "$($db.FullName)-shm") | Where-Object { Test-Path -LiteralPath $_ }) { [void](Move-ToBackup $f $pr.Path) }
                        Log 'OK' "ฐานข้อมูล $($db.Name) เสีย - ย้ายไปโฟลเดอร์สำรอง Thunderbird จะสร้างใหม่"
                    } else {
                        Copy-Item -LiteralPath $db.FullName (Join-Path $backupDir "$($db.Name).damaged") -Force -ErrorAction SilentlyContinue
                        Log 'WARN' "ฐานข้อมูล $($db.Name) เสีย ($check) - เก็บสำเนาไว้ในโฟลเดอร์สำรอง ต้องกู้คืนเอง (ไม่ลบให้เพราะมีข้อมูลสำคัญ)"
                        $sync.OptWarn++
                    }
                    continue
                }
                if ($rebuildableDb -notcontains $db.Name) {   # address book, OpenPGP keys, calendar: keep a copy first
                    Copy-Item -LiteralPath $db.FullName (Join-Path $backupDir $db.Name) -Force -ErrorAction SilentlyContinue
                }
                $before = $db.Length
                $r = Invoke-Sqlite $db.FullName 'VACUUM;'
                if ($r -like 'error*') { Log 'WARN' "บีบอัด $($db.Name) ไม่ได้ ($r)"; continue }
                $saved += $before - (Get-Item -LiteralPath $db.FullName).Length; $okCount++
            }
            $sync.OptSaved += $saved
            Log 'OK' "ตรวจและบีบอัดฐานข้อมูล $okCount/$($dbs.Count) ไฟล์ - ลดขนาดได้ $([math]::Round([math]::Max(0, $saved) / 1MB, 1)) MB"
        } else { Log 'INFO' 'Windows นี้ไม่มี SQLite ในตัว - ข้ามการตรวจฐานข้อมูล' }

        # 3. settings files that Thunderbird rewrites anyway
        foreach ($j in @(Get-ChildItem $pr.Path -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $bad = $false
            try { $txt = [IO.File]::ReadAllText($j.FullName); if ($txt.Trim()) { $null = $txt | ConvertFrom-Json -ErrorAction Stop } else { $bad = $true } }
            catch { $bad = $true }
            if (-not $bad) { continue }
            if ($rebuildableJson -contains $j.Name) {
                if (Move-ToBackup $j.FullName $pr.Path) { Log 'OK' "ไฟล์ตั้งค่า $($j.Name) เสีย - ย้ายออก Thunderbird จะสร้างใหม่" }
            } elseif ($j.Name -notlike 'logins*') {
                Log 'WARN' "ไฟล์ $($j.Name) อ่านไม่ได้ - ไม่ได้แก้ไขให้"; $sync.OptWarn++
            } else {
                Log 'WARN' "ไฟล์รหัสผ่าน $($j.Name) อ่านไม่ได้ - อาจต้องใส่รหัสผ่านใหม่"; $sync.OptWarn++
            }
        }

        # 4. let Thunderbird compact folders by itself (removes deleted mail, keeps mailboxes small)
        try {
            Set-Prefs $pr.Path @{ 'mail.prompt_purge_threshhold' = 'true'; 'mail.purge_threshhold_mb' = '20'; 'mail.purge.ask' = 'false' }
            Log 'OK' 'เปิด Auto-Compact (บีบอัดโฟลเดอร์อัตโนมัติเมื่อเกิน 20 MB)'
        } catch { Log 'WARN' "ตั้งค่า Auto-Compact ไม่ได้: $($_.Exception.Message)" }

        # 5. Trash / Junk that should be emptied
        foreach ($acc in $profAccounts) {
            if (-not $acc.Dir -or -not (Test-Path -LiteralPath $acc.Dir)) { continue }
            Get-ChildItem -LiteralPath $acc.Dir -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in 'Trash', 'Junk', 'Spam', 'Deleted Items', 'Deleted Messages' -and $_.Length -gt 300MB } |
                ForEach-Object {
                    Log 'WARN' "$($acc.Email): โฟลเดอร์ $($_.Name) ใหญ่ $([math]::Round($_.Length / 1MB)) MB - ควรคลิกขวา > Empty $($_.Name)"
                    $sync.OptWarn++
                }
        }
    }

    try {
        if ($opt.Mode -eq 'login') {
            $pw = $opt.Login.Password; $opt.Login.Password = $null
            $in = Test-Pop3Login $opt.Login $pw
            $res = $in
            if ($opt.Login.SmtpHost) {
                $out = Test-SmtpLogin $opt.Login $pw
                $res = @{ Ok = ($in.Ok -and $out.Ok); RecvOk = $in.Ok; SendOk = $out.Ok
                          Summary = "รับเมล: $(if ($in.Ok) { 'ได้' } else { 'ไม่ได้' })  •  ส่งเมล: $(if ($out.Ok) { 'ได้' } else { 'ไม่ได้' })  -  $($in.Summary)"
                          Text = "[ รับเมล - POP3 ]`r`n$($in.Text)`r`n`r`n[ ส่งเมล - SMTP ]`r`n$($out.Text)" }
            }
            $pw = $null
            $sync.LoginResult = $res
            return
        }
        $tbRunning = [bool](Get-Process thunderbird -ErrorAction SilentlyContinue)
        Prog 3 'กำลังค้นหาโปรไฟล์ Thunderbird...'
        $profiles = @(Get-TbProfiles)   # @() - a single PSCustomObject has no .Count in PowerShell 5.1
        $accounts = @(foreach ($pr in $profiles) { Get-Accounts $pr })
        if (-not $accounts) {
            Log 'WARN' $(if ($profiles) { "พบโปรไฟล์ Thunderbird $($profiles.Count) โปรไฟล์ แต่ไม่มีบัญชีอีเมล" }
                         else { 'ไม่พบโปรไฟล์ Thunderbird - ถ้าใช้ Thunderbird Portable หรือโปรไฟล์อยู่ที่อื่น กด "เพิ่มโปรไฟล์เอง"' })
            $sync.Results = @(); return
        }
        $stuckList = @(Get-StuckThunderbird $profiles)
        $wrongDefault = Get-WrongDefaults $profiles $accounts; $defaultFixed = @{}
        $crashByRoot = @{}; foreach ($r in @($profiles | Where-Object { $_.Root } | ForEach-Object { $_.Root } | Sort-Object -Unique)) { $crashByRoot[$r] = Get-CrashCount $r }
        $addonsByProfile = @{}; foreach ($pr in $profiles) { $addonsByProfile[$pr.Path] = @(Get-ActiveAddons $pr.Path) }
        foreach ($k in @($wrongDefault.Keys)) { Log 'WARN' "Thunderbird เปิดโปรไฟล์ $(Split-Path $wrongDefault[$k].Current -Leaf) แต่เมลอยู่ในโปรไฟล์ $(Split-Path $k -Leaf)" }
        foreach ($s in $stuckList) { Log 'WARN' "Thunderbird ค้างอยู่เบื้องหลัง: PID $($s.Id) ($($s.Why)) ถือโปรไฟล์ $(Split-Path $s.Profile -Leaf) ไว้" }

        if ($opt.Mode -eq 'fix') {
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            Log 'INFO' "เริ่มแก้ไข $(Get-Date)   Admin=$($opt.IsAdmin)  RebuildIndex=$($opt.RebuildIndex)"
            # nothing is touched unless Thunderbird is really closed
            $targets  = if (Stop-Thunderbird) { @($accounts | Where-Object { $opt.Targets -contains $_.Key }) } else { @() }
            $tbRunning = [bool](Get-Process thunderbird -ErrorAction SilentlyContinue)
            $profUsed = @($targets | ForEach-Object { $_.Profile } | Sort-Object Path -Unique)

            foreach ($pr in $profUsed) {
                Remove-Locks $pr
                if ($opt.Defender -and $opt.IsAdmin) {
                    try { Add-MpPreference -ExclusionPath $pr.Path -ErrorAction Stop; Log 'OK' "เพิ่มข้อยกเว้น Windows Defender: $($pr.Path)" }
                    catch { Log 'WARN' "เพิ่มข้อยกเว้น Defender ไม่ได้: $($_.Exception.Message)" }
                }
            }
            if ($targets) { Clear-TbTemp $profUsed }

            for ($i = 0; $i -lt $targets.Count; $i++) {
                Prog (10 + 50 * $i / $targets.Count) "กำลังแก้ไข $($targets[$i].Email) ($($i + 1)/$($targets.Count))"
                Repair-Account $targets[$i]
            }
            Log 'STEP' 'สแกนตรวจสอบอีกครั้งหลังแก้ไข'
            $stuckList = @(Get-StuckThunderbird $profiles)
            $accounts = @(foreach ($pr in $profiles) { Get-Accounts $pr })   # prefs.js may have changed
            $wrongDefault = Get-WrongDefaults $profiles $accounts
        }

        if ($opt.Mode -eq 'optimize') {
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            Log 'INFO' "เริ่ม Optimize $(Get-Date)   Admin=$($opt.IsAdmin)"
            if (Stop-Thunderbird) {
                Clear-TbTemp $profiles
                for ($i = 0; $i -lt $profiles.Count; $i++) {
                    Prog (10 + 50 * $i / $profiles.Count) "กำลัง Optimize โปรไฟล์ $($i + 1)/$($profiles.Count)"
                    $pr = $profiles[$i]
                    Optimize-Profile $pr @($accounts | Where-Object { $_.Profile.Path -eq $pr.Path })
                }
                $sync.OptDone = $true
            }
            $tbRunning = [bool](Get-Process thunderbird -ErrorAction SilentlyContinue)
            Log 'STEP' 'สแกนตรวจสอบอีกครั้งหลัง Optimize'
            $stuckList = @(Get-StuckThunderbird $profiles)
            $accounts = @(foreach ($pr in $profiles) { Get-Accounts $pr })
            $wrongDefault = Get-WrongDefaults $profiles $accounts
        }

        $base = if ($opt.Mode -eq 'scan') { 5 } else { 60 }
        $results = @()
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            Prog ($base + (95 - $base) * $i / $accounts.Count) "กำลังสแกน $($accounts[$i].Email) ($($i + 1)/$($accounts.Count))"
            $r = Test-Account $accounts[$i] $tbRunning
            $results += $r
            $lvl = @{ ok = 'OK'; warn = 'WARN'; problem = 'ERR' }[$r.Status]
            Log $lvl "$($r.Email): $(if ($r.Issues) { ($r.Issues | ForEach-Object { $_.Text }) -join ' | ' } else { 'ปกติ' })"
        }
        $sync.Results   = $results
        $sync.TbRunning = $tbRunning
        if ($backupDir) { Log 'INFO' "โฟลเดอร์สำรอง + log: $backupDir" }
    }
    catch { Log 'ERR' "เกิดข้อผิดพลาด: $($_.Exception.Message)" }
    finally { Prog 100 $null; $sync.Done = $true }
}

# ================================================================================
#  LOOK & FEEL
# ================================================================================
$fontName = if ((New-Object Drawing.Text.InstalledFontCollection).Families.Name -contains 'Leelawadee UI') { 'Leelawadee UI' } else { 'Segoe UI' }
function F($size, $style = 'Regular') { New-Object Drawing.Font($fontName, [single]$size, [Drawing.FontStyle]$style) }
function Hex($h) { [Drawing.ColorTranslator]::FromHtml($h) }
$C = @{
    Bg = Hex '#F1F4F9'; Card = [Drawing.Color]::White; Border = Hex '#E2E8F0'
    Text = Hex '#0F172A'; Muted = Hex '#64748B'; Accent = Hex '#2563EB'; AccentDark = Hex '#1D4ED8'; AccentSoft = Hex '#93B4F5'
    Green = Hex '#16A34A'; Amber = Hex '#D97706'; Red = Hex '#DC2626'; ToggleOff = Hex '#CBD5E1'
    LogBg = Hex '#0F172A'; LogText = Hex '#CBD5E1'
}

function New-RoundPath([Drawing.RectangleF]$r, [single]$rad) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $rad * 2
    $p.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure(); $p
}

function New-Label($parent, $text, $x, $y, $font, $color, $w = 0) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = 'Transparent'
    $l.Location = New-Object Drawing.Point($x, $y)
    if ($w) { $l.Size = New-Object Drawing.Size($w, ($font.Height + 4)) } else { $l.AutoSize = $true }
    $parent.Controls.Add($l); $l
}

function New-Card($parent, $x, $y, $w, $h, $title, $bg = $C.Card, $titleColor = $C.Text) {
    $p = New-Object Windows.Forms.Panel
    $p.SetBounds($x, $y, $w, $h); $p.BackColor = $bg
    $p.Add_Paint({ param($s, $e)
        $pen = New-Object Drawing.Pen($(if ($s.BackColor -eq $C.Card) { $C.Border } else { $s.BackColor }))
        $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1); $pen.Dispose() })
    if ($title) { New-Label $p $title 18 12 (F 11 'Bold') $titleColor | Out-Null }
    $parent.Controls.Add($p); $p
}

function New-Btn($parent, $text, $x, $y, $w, $h, [switch]$Primary, $bg, $hover) {
    $b = New-Object Windows.Forms.Button
    $b.SetBounds($x, $y, $w, $h); $b.Text = $text; $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'
    $b.Font = if ($Primary) { F 10.5 'Bold' } else { F 10 }
    if ($Primary) {
        $b.BackColor = $C.Accent; $b.ForeColor = 'White'; $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $C.AccentDark
    } elseif ($bg) {
        $b.BackColor = $bg; $b.ForeColor = 'White'; $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $hover
    } else {
        $b.BackColor = 'White'; $b.ForeColor = $C.Text
        $b.FlatAppearance.BorderColor = Hex '#CBD5E1'; $b.FlatAppearance.MouseOverBackColor = Hex '#F1F5F9'
    }
    $parent.Controls.Add($b); $b
}

function New-Toggle($parent, $x, $y, $text) {
    $t = New-Object Windows.Forms.Panel
    $t.SetBounds($x, $y, 40, 22); $t.BackColor = $parent.BackColor; $t.Cursor = 'Hand'; $t.Tag = $false
    $t.Add_Paint({ param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $on = [bool]$s.Tag
        $br = New-Object Drawing.SolidBrush($(if ($on) { $C.Accent } else { $C.ToggleOff }))
        $g.FillPath($br, (New-RoundPath (New-Object Drawing.RectangleF(0, 0, ($s.Width - 1), ($s.Height - 1))) 10.5))
        $g.FillEllipse([Drawing.Brushes]::White, $(if ($on) { $s.Width - 20 } else { 3 }), 3, 16, 16)
        $br.Dispose() })
    $t.Add_Click({ $this.Tag = -not [bool]$this.Tag; $this.Invalidate() })
    $parent.Controls.Add($t)
    $l = New-Label $parent $text ($x + 50) ($y + 1) (F 9.5) $C.Text
    $l.Cursor = 'Hand'; $l.Tag = $t
    $l.Add_Click({ $this.Tag.Tag = -not [bool]$this.Tag.Tag; $this.Tag.Invalidate() })
    $t
}

function Format-Size([int64]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f ($b / 1KB) }
}

# ================================================================================
#  WINDOW
# ================================================================================
$W = 1000
$form = New-Object Windows.Forms.Form
$form.Text = 'Thunderbird Mailbox Fix Tool'
$form.ClientSize = New-Object Drawing.Size($W, 716)
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.BackColor = $C.Bg; $form.Font = F 9.5
# Where Thunderbird is installed: registry App Paths (any install folder), the usual folders,
# a per-user install, and - only when asked, it is slower - the Microsoft Store version.
function Find-Thunderbird([switch]$IncludeStore) {
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\thunderbird.exe',
                   'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\thunderbird.exe',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\thunderbird.exe') {
        $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).'(default)'
        if ($v) { $v = [Environment]::ExpandEnvironmentVariables($v.Trim('"')); if (Test-Path -LiteralPath $v) { return @{ Exe = $v } } }
    }
    foreach ($d in $env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, (Join-Path "$env:LOCALAPPDATA" 'Programs')) {
        if (-not $d) { continue }
        $e = Join-Path $d 'Mozilla Thunderbird\thunderbird.exe'
        if (Test-Path -LiteralPath $e) { return @{ Exe = $e } }
    }
    if ($IncludeStore) {
        try {
            $pkg = Get-AppxPackage -Name '*Thunderbird*' -ErrorAction Stop | Select-Object -First 1
            if ($pkg) {
                $appId = (Get-AppxPackageManifest $pkg).Package.Applications.Application | Select-Object -First 1 -ExpandProperty Id
                return @{ AppId = "$($pkg.PackageFamilyName)!$appId" }
            }
        } catch {}
    }
    $null
}
$tbExe = (Find-Thunderbird).Exe
$selfExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$iconSrc = if ($selfExe -notmatch '\\powershell(_ise)?\.exe$') { $selfExe } else { $tbExe }   # packaged exe has its own icon
if ($iconSrc) { try { $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon($iconSrc) } catch {} }

# --- Header ---------------------------------------------------------------------
$hdr = New-Object Windows.Forms.Panel
$hdr.SetBounds(0, 0, $W, 96)
$hdr.Add_Paint({ param($s, $e)
    $g = $e.Graphics
    $br = New-Object Drawing.Drawing2D.LinearGradientBrush($s.ClientRectangle, (Hex '#0B2559'), (Hex '#2563EB'), [single]0)
    $g.FillRectangle($br, $s.ClientRectangle); $br.Dispose()
    $g.SmoothingMode = 'AntiAlias'
    $circle = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(40, 255, 255, 255))
    $g.FillEllipse($circle, 24, 18, 58, 58); $circle.Dispose()
    [Windows.Forms.TextRenderer]::DrawText($g, [string][char]0x2709, (New-Object Drawing.Font('Segoe UI Symbol', 22)),
        (New-Object Drawing.Rectangle(24, 18, 58, 58)), [Drawing.Color]::White, [Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter')
})
$form.Controls.Add($hdr)
$lblTitle = New-Label $hdr 'Thunderbird Mailbox Fix Tool' 96 14 (F 17 'Bold') ([Drawing.Color]::White)
New-Label $hdr "v$AppVersion" ($lblTitle.Left + $lblTitle.PreferredWidth + 4) 25 (F 9 'Bold') (Hex '#93C5FD') | Out-Null
New-Label $hdr 'สแกนทุกบัญชีอีเมล - เขียนกล่องจดหมายไม่ได้ / เมลไม่เข้า / ส่งไม่ออก - และแก้ไขอัตโนมัติ' 99 54 (F 10) (Hex '#DBEAFE') | Out-Null

$badge = New-Object Windows.Forms.Label
$badge.SetBounds($W - 24 - 286, 16, 286, 28); $badge.TextAlign = 'MiddleCenter'; $badge.Font = F 9.5 'Bold'; $badge.ForeColor = 'White'
if ($isAdmin) { $badge.Text = [string][char]0x25CF + '  Administrator - สแกนทุกผู้ใช้ในเครื่อง'; $badge.BackColor = $C.Green }
else          { $badge.Text = [string][char]0x25CF + '  ไม่ใช่ Admin - สแกนเฉพาะผู้ใช้นี้'; $badge.BackColor = $C.Amber }
$badge.Region = New-Object Drawing.Region (New-RoundPath (New-Object Drawing.RectangleF(0, 0, 286, 28)) 14)
$hdr.Controls.Add($badge)

$btnTB     = New-Btn $hdr 'เปิด Thunderbird' ($W - 24 - 138) 54 138 30 -bg (Hex '#1D4ED8') -hover (Hex '#1E40AF')
$btnBackup = New-Btn $hdr 'โฟลเดอร์สำรอง' ($W - 24 - 138 - 8 - 140) 54 140 30 -bg (Hex '#1D4ED8') -hover (Hex '#1E40AF')
$btnBackup.Enabled = $false

# --- Toolbar --------------------------------------------------------------------
$bar = New-Card $form 24 112 952 72 $null
$btnScan   = New-Btn $bar 'สแกนใหม่' 14 13 106 46
$btnFixSel = New-Btn $bar 'แก้ไขบัญชีที่เลือก' 128 13 150 46
$btnFixAll = New-Btn $bar 'แก้ไขอัตโนมัติทุกบัญชีที่มีปัญหา' 286 13 248 46 -Primary
$btnOpt    = New-Btn $bar 'Optimize' 542 13 120 46 -bg (Hex '#0F766E') -hover (Hex '#115E59')
$btnOpt.Font = F 10.5 'Bold'
$tglIndex  = New-Toggle $bar 684 11 'สร้างดัชนีใหม่ (.msf)'
$tglDef    = New-Toggle $bar 684 40 'ยกเว้นจาก Defender'
$tt = New-Object Windows.Forms.ToolTip
$tt.SetToolTip($btnFixAll, 'ปิด Thunderbird แล้วแก้ไขทุกบัญชีที่สถานะ "มีปัญหา" จากนั้นสแกนซ้ำเพื่อยืนยัน')
$tt.SetToolTip($btnFixSel, 'แก้ไขเฉพาะบัญชีที่ติ๊กเลือกในรายการ (แก้ทุกขั้นตอนแม้ไม่พบปัญหา)')
$tt.SetToolTip($btnOpt, 'ปรับแต่งให้ Thunderbird เสถียร: ตรวจ/บีบอัดฐานข้อมูล, ซ่อมไฟล์ตั้งค่าที่เสีย, ล้างแคช, เปิด Auto-Compact')
$tt.SetToolTip($tglIndex, 'ย้ายไฟล์ดัชนี .msf ทั้งหมดออกตอนแก้ไข ให้ Thunderbird สร้างใหม่ - ใช้เมื่อยังพบข้อผิดพลาดซ้ำ')
$tt.SetToolTip($tglDef, 'เพิ่มโฟลเดอร์โปรไฟล์ Thunderbird เป็นข้อยกเว้นของ Windows Defender (ต้องเป็น Admin)')

# --- Account list ---------------------------------------------------------------
$listCard = New-Card $form 24 196 952 300 'บัญชีอีเมลใน Thunderbird'
$lblSummary = New-Label $listCard '' 420 15 (F 9.5) $C.Muted 400
$lblSummary.TextAlign = 'MiddleRight'
$lnkAdd  = New-Object Windows.Forms.LinkLabel
$lnkAll  = New-Object Windows.Forms.LinkLabel
$lnkNone = New-Object Windows.Forms.LinkLabel
foreach ($pair in @(@($lnkAdd, '+ เพิ่มโปรไฟล์เอง', 700), @($lnkAll, 'เลือกทั้งหมด', 832), @($lnkNone, 'ล้างการเลือก', 892))) {
    $pair[0].Text = $pair[1]; $pair[0].Location = New-Object Drawing.Point($pair[2], 16); $pair[0].AutoSize = $true
    $pair[0].Font = F 9; $pair[0].LinkColor = $C.Accent; $pair[0].LinkBehavior = 'HoverUnderline'; $pair[0].BackColor = 'Transparent'
    $listCard.Controls.Add($pair[0])
}
$lnkNone.Left = 952 - 18 - $lnkNone.PreferredWidth
$lnkAll.Left  = $lnkNone.Left - 14 - $lnkAll.PreferredWidth
$lnkAdd.Left  = $lnkAll.Left - 22 - $lnkAdd.PreferredWidth
$lnkAdd.Font  = F 9 'Bold'
$lblSummary.Left = $lnkAdd.Left - 18 - $lblSummary.Width

$lv = New-Object Windows.Forms.ListView
$lv.SetBounds(1, 46, 950, 253)
$lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.HideSelection = $true   # keeps status colours readable
$lv.BorderStyle = 'None'; $lv.HeaderStyle = 'Nonclickable'; $lv.Font = F 10; $lv.ForeColor = $C.Text
$il = New-Object Windows.Forms.ImageList; $il.ImageSize = New-Object Drawing.Size(1, 32); $lv.SmallImageList = $il
foreach ($col in @(@('บัญชีอีเมล', 270), @('ประเภท', 100), @('ผู้ใช้ Windows', 115), @('ขนาด', 80), @('สถานะ', 120), @('ปัญหาที่พบ', 240))) {
    [void]$lv.Columns.Add($col[0], $col[1])
}
$listCard.Controls.Add($lv)
$lblEmpty = New-Label $listCard 'กำลังสแกนบัญชี...' 0 160 (F 11) $C.Muted 950
$lblEmpty.TextAlign = 'MiddleCenter'; $lblEmpty.BackColor = 'White'; $lblEmpty.BringToFront()

# --- Progress -------------------------------------------------------------------
$lblStatus = New-Label $form 'พร้อมใช้งาน' 24 506 (F 9.5) $C.Muted 800
$lblPct    = New-Label $form '' 876 506 (F 9.5 'Bold') $C.Accent 100
$lblPct.TextAlign = 'TopRight'
$track = New-Object Windows.Forms.Panel
$track.SetBounds(24, 532, 952, 8); $track.BackColor = Hex '#E2E8F0'
$track.Region = New-Object Drawing.Region (New-RoundPath (New-Object Drawing.RectangleF(0, 0, 952, 8)) 4)
$fill = New-Object Windows.Forms.Panel
$fill.SetBounds(0, 0, 0, 8); $fill.BackColor = $C.Accent
$track.Controls.Add($fill); $form.Controls.Add($track)

# --- Details + log --------------------------------------------------------------
$detCard = New-Card $form 24 552 466 150 'รายละเอียดบัญชี'
$btnLogin = New-Btn $detCard 'ทดสอบรับ/ส่งเมล' (466 - 18 - 140) 8 140 28
$btnLogin.Font = F 9.5 'Bold'; $btnLogin.ForeColor = $C.Accent; $btnLogin.Enabled = $false
$tt.SetToolTip($btnLogin, 'ล็อกอินเข้าเซิร์ฟเวอร์รับเมล (POP3) และส่งเมล (SMTP) แบบเดียวกับ Get Messages / Send เพื่อหาสาเหตุ (ไม่ส่งเมลจริง ไม่บันทึกรหัสผ่าน)')
$det = New-Object Windows.Forms.RichTextBox
$det.SetBounds(18, 40, 436, 104); $det.BorderStyle = 'None'; $det.ReadOnly = $true; $det.BackColor = 'White'
$det.Font = F 9.5; $det.ForeColor = $C.Muted; $det.Text = 'คลิกที่บัญชีในรายการเพื่อดูรายละเอียด'
$detCard.Controls.Add($det)

$logCard = New-Card $form 510 552 466 150 'บันทึกการทำงาน' $C.LogBg (Hex '#E2E8F0')
$log = New-Object Windows.Forms.RichTextBox
$log.SetBounds(18, 40, 436, 104); $log.BorderStyle = 'None'; $log.ReadOnly = $true
$log.BackColor = $C.LogBg; $log.ForeColor = $C.LogText; $log.Font = F 9
$logCard.Controls.Add($log)

# ================================================================================
#  BEHAVIOUR
# ================================================================================
$script:results = @(); $script:fixedKeys = @(); $script:sync = $null; $script:ps = $null; $script:extraProfiles = @()
$script:mode = $null; $script:backupDir = $null
$statusStyle = @{
    ok      = @{ Text = [string][char]0x25CF + ' ปกติ';         Color = $C.Green }
    warn    = @{ Text = [string][char]0x25CF + ' ควรตรวจสอบ';   Color = $C.Amber }
    problem = @{ Text = [string][char]0x25CF + ' มีปัญหา';       Color = $C.Red }
    fixed   = @{ Text = [string][char]0x25CF + ' แก้ไขแล้ว';     Color = $C.Green }
}
# Thai UI font has no check/cross glyphs - draw those with Segoe UI Symbol
$fSym = New-Object Drawing.Font('Segoe UI Symbol', 9)

function Add-Run($box, $text, $color, $font) {
    $box.SelectionStart = $box.TextLength; $box.SelectionLength = 0
    $box.SelectionColor = $color; $box.SelectionFont = $font
    $box.AppendText($text)
}

function Add-LogLine($level, $msg) {
    $color, $prefix = switch ($level) {
        'STEP' { (Hex '#60A5FA'), ([string][char]0x25B8 + ' ') }
        'OK'   { (Hex '#4ADE80'), ([string][char]0x2714 + ' ') }
        'WARN' { (Hex '#FBBF24'), '! ' }
        'ERR'  { (Hex '#F87171'), ([string][char]0x2716 + ' ') }
        default { $C.LogText, '   ' }
    }
    Add-Run $log $prefix $color $fSym
    Add-Run $log "$msg`r`n" $color $log.Font
    $log.ScrollToCaret()
}

function Add-Det($text, $color, $font, $symbol) {
    if ($symbol) { Add-Run $det "$symbol " $color $fSym }
    Add-Run $det "$text`r`n" $color $font
}

function Show-Details($r) {
    $btnLogin.Enabled = [bool]($r -and $r.RawType -eq 'pop3' -and -not $script:busy)
    $det.Clear()
    if (-not $r) { $det.SelectionColor = $C.Muted; $det.AppendText('คลิกที่บัญชีในรายการเพื่อดูรายละเอียด'); return }
    Add-Det $r.Email $C.Text (F 10.5 'Bold')
    Add-Det "$($r.Type)$(if ($r.Server) { '  •  ' + $r.Server })  •  ผู้ใช้ Windows: $($r.User)" $C.Muted (F 9)
    Add-Det "โฟลเดอร์: $($r.Dir)" $C.Muted (F 9)
    if (-not $r.Issues) { Add-Det 'ไม่พบปัญหา' $C.Green (F 9.5 'Bold') ([string][char]0x2714); return }
    foreach ($i in $r.Issues) {
        # (not "$c": PowerShell names are case-insensitive and it would hide the $C colour table)
        $issueColor = if ($i.Fixable -or $i.Code -in 'DIR_MISSING', 'NET_IN', 'NET_OUT', 'DISK') { $C.Red } else { $C.Amber }
        $tag = if ($i.Fixable) { '' } else { '  (ต้องแก้เอง)' }
        Add-Det ("• " + $i.Text + $tag) $issueColor (F 9.5)
    }
    $det.SelectionStart = 0; $det.ScrollToCaret()
}

function Update-AccountList {
    $lv.BeginUpdate(); $lv.Items.Clear()
    foreach ($r in $script:results) {
        $state = if ($r.Status -ne 'problem' -and $script:fixedKeys -contains $r.Key) { 'fixed' } else { $r.Status }
        $it = New-Object Windows.Forms.ListViewItem($r.Email)
        $it.UseItemStyleForSubItems = $false; $it.Tag = $r
        [void]$it.SubItems.Add($r.Type)
        [void]$it.SubItems.Add($r.User)
        [void]$it.SubItems.Add((Format-Size $r.Size))
        $st = $it.SubItems.Add($statusStyle[$state].Text)
        $st.ForeColor = $statusStyle[$state].Color; $st.Font = F 10 'Bold'
        $summary = if ($r.Issues) { $r.Issues[0].Text + $(if ($r.Issues.Count -gt 1) { "  (+$($r.Issues.Count - 1))" }) } else { '-' }
        $sub = $it.SubItems.Add($summary); $sub.ForeColor = $C.Muted
        $it.Checked = ($r.Status -eq 'problem')
        [void]$lv.Items.Add($it)
    }
    $lv.EndUpdate()
    $nProb = @($script:results | Where-Object Status -eq 'problem').Count
    $nWarn = @($script:results | Where-Object Status -eq 'warn').Count
    $lblSummary.Text = "พบ $($script:results.Count) บัญชี   •   มีปัญหา $nProb   •   ควรตรวจสอบ $nWarn"
    $lblEmpty.Visible = ($script:results.Count -eq 0)
    if ($script:results.Count -eq 0) {
        $lblEmpty.Text = "ไม่พบบัญชีอีเมลใน Thunderbird`r`nถ้าใช้ Thunderbird Portable หรือโปรไฟล์อยู่ที่อื่น กด ""+ เพิ่มโปรไฟล์เอง"" ด้านบนขวา"
        $lblEmpty.Height = 48; $lblEmpty.Top = 140
    }
    $first = $lv.Items | Where-Object { $_.Tag.Status -ne 'ok' } | Select-Object -First 1
    if (-not $first -and $lv.Items.Count) { $first = $lv.Items[0] }
    if ($first) { $first.Selected = $true } else { Show-Details $null }
}

function Set-Busy([bool]$busy) {
    $script:busy = $busy
    foreach ($b in $btnScan, $btnFixSel, $btnFixAll, $btnOpt) { $b.Enabled = -not $busy }
    $btnLogin.Enabled = [bool]((-not $busy) -and $lv.SelectedItems.Count -and $lv.SelectedItems[0].Tag.RawType -eq 'pop3')
    $btnFixAll.BackColor = if ($busy) { $C.AccentSoft } else { $C.Accent }
    $btnOpt.BackColor    = if ($busy) { Hex '#99C9C4' } else { Hex '#0F766E' }
    $lv.Enabled = -not $busy
    $form.Cursor = if ($busy) { 'AppStarting' } else { 'Default' }
}

function Start-Engine($mode, $keys, $login) {
    Set-Busy $true
    $script:mode = $mode
    $script:backupDir = if ($mode -in 'fix', 'optimize') {
        Join-Path ([Environment]::GetFolderPath('Desktop')) "Thunderbird-Fix-Backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    $script:sync = [hashtable]::Synchronized(@{
        Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Progress = 0; StatusText = ''; Done = $false; Results = $null; TbRunning = $false
        OptDone = $false; OptSaved = [int64]0; OptWarn = 0; LoginResult = $null })
    $opt = @{ Mode = $mode; Targets = @($keys); IsAdmin = $isAdmin; BackupDir = $script:backupDir; Login = $login
              ExtraProfiles = @($script:extraProfiles)
              RebuildIndex = [bool]$tglIndex.Tag; Defender = [bool]$tglDef.Tag }
    $script:ps = [PowerShell]::Create()
    [void]$script:ps.AddScript($engine).AddArgument($script:sync).AddArgument($opt)
    [void]$script:ps.BeginInvoke()
    $timer.Start()
}

# Small password prompt for the login test - the password only lives in memory for this one test
function Read-Password($r) {
    $d = New-Object Windows.Forms.Form
    $d.Text = 'ทดสอบการรับ/ส่งเมล'; $d.ClientSize = New-Object Drawing.Size(440, 214)
    $d.FormBorderStyle = 'FixedDialog'; $d.StartPosition = 'CenterParent'; $d.MinimizeBox = $false; $d.MaximizeBox = $false
    $d.BackColor = 'White'; $d.Font = F 9.5; $d.Icon = $form.Icon
    New-Label $d $r.Email 20 16 (F 11 'Bold') $C.Text | Out-Null
    New-Label $d "รับเมล:  $($r.UserName) @ $($r.Server):$($r.Port)$(if ($r.SocketType -eq '3') { ' (SSL)' })" 20 44 (F 9) $C.Muted | Out-Null
    New-Label $d "ส่งเมล:  $(if ($r.SmtpHost) { "$($r.SmtpHost):$($r.SmtpPort)" } else { '(ไม่ได้ตั้งค่า)' })" 20 62 (F 9) $C.Muted | Out-Null
    New-Label $d 'ใส่รหัสผ่านของบัญชีนี้ เพื่อทดสอบล็อกอินแบบเดียวกับ Get Messages / Send' 20 90 (F 9.5) $C.Text | Out-Null
    $tb = New-Object Windows.Forms.TextBox
    $tb.SetBounds(20, 116, 400, 28); $tb.UseSystemPasswordChar = $true; $tb.Font = F 11
    $d.Controls.Add($tb)
    New-Label $d 'ไม่ส่งเมลจริง และไม่บันทึกรหัสผ่าน ใช้ทดสอบครั้งนี้ครั้งเดียว' 20 150 (F 8.5) $C.Muted | Out-Null
    $ok = New-Btn $d 'ทดสอบ' 234 170 90 32 -Primary
    $cancel = New-Btn $d 'ยกเลิก' 330 170 90 32
    $ok.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'
    $d.AcceptButton = $ok; $d.CancelButton = $cancel
    $pw = if ($d.ShowDialog($form) -eq 'OK' -and $tb.Text) { $tb.Text } else { $null }
    $tb.Clear(); $d.Dispose()
    $pw
}

function Start-Fix($keys) {
    if (-not $keys) { return }
    if (Get-Process thunderbird -ErrorAction SilentlyContinue) {
        $a = [Windows.Forms.MessageBox]::Show($form, "Thunderbird กำลังเปิดอยู่ ระบบจะปิด Thunderbird ก่อนเริ่มแก้ไข`r`n`r`nดำเนินการต่อหรือไม่?",
            'Thunderbird Fix', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
    }
    $script:fixedKeys = @($keys)
    Start-Engine 'fix' $keys
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 120
$timer.Add_Tick({ try {
    $item = $null
    while ($script:sync.Queue.TryDequeue([ref]$item)) { Add-LogLine $item[0] $item[1] }
    $pct = [math]::Min(100, [math]::Max(0, $script:sync.Progress))
    $fill.Width = [int](952 * $pct / 100); $lblPct.Text = "$pct%"
    if ($script:sync.StatusText) { $lblStatus.Text = $script:sync.StatusText; $lblStatus.ForeColor = $C.Muted }
    if (-not ($script:sync.Done -and $script:sync.Queue.IsEmpty)) { return }

    $timer.Stop(); $script:ps.Dispose()

    if ($script:mode -eq 'login') {   # login test leaves the account list as it is
        Set-Busy $false
        $lr = $script:sync.LoginResult
        if ($lr) {
            $lblStatus.Text = "$($script:loginEmail): $($lr.Summary)"; $lblStatus.ForeColor = $(if ($lr.Ok) { $C.Green } else { $C.Red })
            [Windows.Forms.MessageBox]::Show($form, $lr.Text, "ทดสอบรับ/ส่งเมล - $($script:loginEmail)", 'OK', $(if ($lr.Ok) { 'Information' } else { 'Error' })) | Out-Null
        }
        return
    }
    $script:results = @($script:sync.Results | Where-Object { $_ })
    Update-AccountList
    Set-Busy $false
    $nProb = @($script:results | Where-Object Status -eq 'problem').Count

    if ($script:mode -eq 'fix') {
        $btnBackup.Enabled = $true
        $done = @($script:results | Where-Object { $script:fixedKeys -contains $_.Key })
        $ok   = @($done | Where-Object Status -ne 'problem').Count
        $bad  = $done.Count - $ok
        if ($bad) {
            $lblStatus.Text = "แก้ไขสำเร็จ $ok บัญชี  •  ยังมีปัญหา $bad บัญชี (ดูรายละเอียดด้านล่าง)"; $lblStatus.ForeColor = $C.Red
            [Windows.Forms.MessageBox]::Show($form, "แก้ไขสำเร็จ $ok บัญชี`r`nยังมีปัญหา $bad บัญชี - คลิกที่บัญชีเพื่อดูสิ่งที่ต้องแก้เอง",
                'Thunderbird Fix', 'OK', 'Warning') | Out-Null
        } else {
            $lblStatus.Text = "แก้ไขเรียบร้อยทั้ง $ok บัญชี  •  เปิด Thunderbird แล้วลองส่ง/รับอีเมลได้เลย"; $lblStatus.ForeColor = $C.Green
            [Windows.Forms.MessageBox]::Show($form, "แก้ไขเรียบร้อยทั้ง $ok บัญชี`r`n`r`nเปิด Thunderbird แล้วลองใช้งาน หากยังพบปัญหาในโฟลเดอร์ใด ให้คลิกขวาที่โฟลเดอร์ > Properties > Repair Folder",
                'Thunderbird Fix', 'OK', 'Information') | Out-Null
        }
    } elseif ($script:mode -eq 'optimize') {
        $btnBackup.Enabled = $true
        $mb  = [math]::Round([math]::Max(0, $script:sync.OptSaved) / 1MB, 1)
        $nW  = $script:sync.OptWarn
        if (-not $script:sync.OptDone) {
            $lblStatus.Text = 'Optimize ไม่สำเร็จ - ปิด Thunderbird ไม่ได้ (ดูบันทึกการทำงาน)'; $lblStatus.ForeColor = $C.Red
        } elseif ($nW) {
            $lblStatus.Text = "Optimize เสร็จ  •  ลดขนาดได้ $mb MB  •  มี $nW รายการควรตรวจสอบ (บรรทัดสีเหลืองในบันทึก)"; $lblStatus.ForeColor = $C.Amber
        } else {
            $lblStatus.Text = "Optimize เสร็จเรียบร้อย  •  ลดขนาดฐานข้อมูลได้ $mb MB"; $lblStatus.ForeColor = $C.Green
        }
        [Windows.Forms.MessageBox]::Show($form, $lblStatus.Text, 'Thunderbird Fix', 'OK', $(if ($script:sync.OptDone -and -not $nW) { 'Information' } else { 'Warning' })) | Out-Null
    } else {
        if ($nProb) { $lblStatus.Text = "สแกนเสร็จ  •  พบ $nProb บัญชีที่มีปัญหา - กด ""แก้ไขอัตโนมัติ"" เพื่อแก้ไข"; $lblStatus.ForeColor = $C.Red }
        else        { $lblStatus.Text = 'สแกนเสร็จ  •  ไม่พบบัญชีที่มีปัญหา'; $lblStatus.ForeColor = $C.Green }
        if ($script:sync.TbRunning) { $lblStatus.Text += '   (Thunderbird เปิดอยู่ จึงข้ามการตรวจไฟล์ถูกล็อก)' }
    }
} catch {
    # never leave the window stuck in "busy" because of a display error
    $timer.Stop(); Set-Busy $false
    $lblStatus.Text = "เกิดข้อผิดพลาดในการแสดงผล: $($_.Exception.Message)"; $lblStatus.ForeColor = $C.Red
} })

$lv.Add_SelectedIndexChanged({ if ($lv.SelectedItems.Count) { Show-Details $lv.SelectedItems[0].Tag } })
$lnkAll.Add_LinkClicked({ foreach ($i in $lv.Items) { $i.Checked = $true } })
$lnkNone.Add_LinkClicked({ foreach ($i in $lv.Items) { $i.Checked = $false } })

$btnScan.Add_Click({ $script:fixedKeys = @(); $log.Clear(); Start-Engine 'scan' @() })
$btnFixAll.Add_Click({
    $keys = @($script:results | Where-Object Status -eq 'problem' | ForEach-Object { $_.Key })
    if (-not $keys) {
        [Windows.Forms.MessageBox]::Show($form, 'ไม่พบบัญชีที่มีปัญหาที่แก้อัตโนมัติได้', 'Thunderbird Fix', 'OK', 'Information') | Out-Null; return }
    Start-Fix $keys
})
$btnFixSel.Add_Click({
    $keys = @($lv.CheckedItems | ForEach-Object { $_.Tag.Key })
    if (-not $keys) {
        [Windows.Forms.MessageBox]::Show($form, 'กรุณาติ๊กเลือกบัญชีที่ต้องการแก้ไขก่อน', 'Thunderbird Fix', 'OK', 'Information') | Out-Null; return }
    Start-Fix $keys
})
$btnOpt.Add_Click({
    $a = [Windows.Forms.MessageBox]::Show($form, 
        "Optimize จะปิด Thunderbird แล้วทำสิ่งต่อไปนี้กับทุกโปรไฟล์:`r`n`r`n" +
        "•  ตรวจความเสียหายและบีบอัดฐานข้อมูล (SQLite)`r`n" +
        "•  ซ่อมไฟล์ตั้งค่าที่เสีย (Thunderbird จะสร้างใหม่)`r`n" +
        "•  ล้างแคชและไฟล์ชั่วคราว`r`n" +
        "•  เปิด Auto-Compact ให้บีบอัดโฟลเดอร์อัตโนมัติ`r`n" +
        "•  แจ้งเตือนโฟลเดอร์ Trash / Junk ที่ใหญ่เกินไป`r`n`r`n" +
        "ไม่มีการลบอีเมล ไฟล์ที่นำออกจะเก็บไว้ในโฟลเดอร์สำรองบน Desktop`r`n`r`nดำเนินการต่อหรือไม่?",
        'Thunderbird Fix - Optimize', 'YesNo', 'Question')
    if ($a -ne 'Yes') { return }
    $script:fixedKeys = @(); $log.Clear()
    Start-Engine 'optimize' @()
})
$btnLogin.Add_Click({
    if (-not $lv.SelectedItems.Count) { return }
    $r = $lv.SelectedItems[0].Tag
    $pw = Read-Password $r
    if (-not $pw) { return }
    $script:loginEmail = $r.Email
    Start-Engine 'login' @() @{ Server = $r.Server; Port = $r.Port; SocketType = $r.SocketType; UserName = $r.UserName; Password = $pw
        SmtpHost = $r.SmtpHost; SmtpPort = $r.SmtpPort; SmtpUser = $r.SmtpUser; SmtpSocket = $r.SmtpSocket; SmtpAuth = $r.SmtpAuth }
    $pw = $null
})
$btnBackup.Add_Click({ if ($script:backupDir -and (Test-Path $script:backupDir)) { Start-Process explorer.exe $script:backupDir } })
# "เปิด Thunderbird" menu: normal start, Troubleshoot Mode (no add-ons), Profile Manager
function Start-Thunderbird([string[]]$tbArgs) {
    $tb = Find-Thunderbird -IncludeStore
    if (-not $tb) { [Windows.Forms.MessageBox]::Show($form, 'ไม่พบโปรแกรม Thunderbird ในเครื่องนี้', 'Thunderbird Fix', 'OK', 'Warning') | Out-Null; return }
    if ($tbArgs -and (Get-Process thunderbird -ErrorAction SilentlyContinue)) {
        # these options only work when Thunderbird starts fresh
        $a = [Windows.Forms.MessageBox]::Show($form, 'ต้องปิด Thunderbird ที่เปิดอยู่ก่อน ปิดให้เลยไหม?', 'Thunderbird Fix', 'YesNo', 'Question')
        if ($a -ne 'Yes') { return }
        Get-Process thunderbird -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        for ($i = 0; $i -lt 30 -and (Get-Process thunderbird -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
        Get-Process thunderbird -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    if ($tb.Exe) {
        if ($tbArgs) { Start-Process $tb.Exe -ArgumentList $tbArgs } else { Start-Process $tb.Exe }
    } elseif ($tb.AppId) {   # Microsoft Store version: no command-line options through the app launcher
        if ($tbArgs) {
            [Windows.Forms.MessageBox]::Show($form, 'Thunderbird จาก Microsoft Store: กดปุ่ม Shift ค้างไว้ตอนเปิด Thunderbird เพื่อเข้า Troubleshoot Mode', 'Thunderbird Fix', 'OK', 'Information') | Out-Null
        }
        Start-Process explorer.exe "shell:AppsFolder\$($tb.AppId)"
    }
}
$tbMenu = New-Object Windows.Forms.ContextMenuStrip
$tbMenu.Font = F 10
$miNormal = $tbMenu.Items.Add('เปิด Thunderbird ตามปกติ')
$miSafe   = $tbMenu.Items.Add('เปิดแบบไม่โหลด Add-on (Troubleshoot Mode) - ใช้เมื่อ Thunderbird ค้าง / ปิดตัวเอง')
$miPm     = $tbMenu.Items.Add('เลือกโปรไฟล์ (Profile Manager) - ใช้เมื่อเปิดมาแล้วเมลหาย')
$miNormal.Add_Click({ Start-Thunderbird @() })
$miSafe.Add_Click({ Start-Thunderbird @('-safe-mode') })
$miPm.Add_Click({ Start-Thunderbird @('-P') })
$btnTB.Text = 'เปิด Thunderbird ▾'
$btnTB.Add_Click({ $tbMenu.Show($btnTB, (New-Object Drawing.Point(0, $btnTB.Height))) })
$lnkAdd.Add_LinkClicked({
    $fb = New-Object Windows.Forms.FolderBrowserDialog
    $fb.Description = 'เลือกโฟลเดอร์โปรไฟล์ Thunderbird (โฟลเดอร์ที่มีไฟล์ prefs.js) เช่น ThunderbirdPortable\Data\profile'
    if ($fb.ShowDialog($form) -ne 'OK') { return }
    # the folder itself, or profiles up to 3 levels below it (e.g. the whole Thunderbird Portable folder)
    $picked = @(Get-ChildItem -LiteralPath $fb.SelectedPath -Filter 'prefs.js' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
    if (-not $picked) {
        [Windows.Forms.MessageBox]::Show($form, 'ไม่พบโปรไฟล์ Thunderbird (ไฟล์ prefs.js) ในโฟลเดอร์นี้', 'Thunderbird Fix', 'OK', 'Warning') | Out-Null
        return
    }
    $script:extraProfiles = @($script:extraProfiles + $picked | Sort-Object -Unique)
    $log.Clear(); Start-Engine 'scan' @()
})

$form.Add_Shown({ $global:TbFixUiShown = $true; Start-Engine 'scan' @() })
$form.Add_FormClosing({
    if ($script:sync -and -not $script:sync.Done) {
        # Windows shutting down / Task Manager: never block it with a question
        if ($_.CloseReason -eq 'UserClosing') {
            $_.Cancel = ([Windows.Forms.MessageBox]::Show($form, 'ระบบกำลังทำงานอยู่ ต้องการปิดหรือไม่?', 'Thunderbird Fix', 'YesNo', 'Warning') -ne 'Yes')
        }
        if (-not $_.Cancel) { $timer.Stop(); try { [void]$script:ps.BeginStop($null, $null) } catch {} }
    }
})

[void]$form.ShowDialog()
try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose()
# End the process now - a background scan must not keep it alive (that left copies "stuck" until a restart).
# The exe launcher exits on its own; only end the process when this script owns it (-File).
if ($PSCommandPath) { [Environment]::Exit(0) }
