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
if (-not $isAdmin -and $PSCommandPath) {
    try {
        Start-Process powershell.exe -Verb RunAs -ErrorAction Stop -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
        exit
    } catch { }   # user pressed "No" on UAC - continue without admin
}

$AppVersion = '1.1.0'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Only one copy at a time - two copies fixing the same profile would fight over the files
$mutex = New-Object Threading.Mutex($false, 'ThunderbirdMailFix-SingleInstance')
$ownsMutex = try { $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $true }
if (-not $ownsMutex) {
    [Windows.Forms.MessageBox]::Show('Thunderbird Mail Fix เปิดอยู่แล้ว', 'Thunderbird Mail Fix', 'OK', 'Information') | Out-Null
    return
}

# Hide the black console window behind the GUI
Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
[Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0) | Out-Null

# ================================================================================
#  ENGINE  (runs in a background runspace so the window never freezes)
#    Mode 'scan' : find every account and test it
#    Mode 'fix'  : repair the accounts in $opt.Targets, then scan again
# ================================================================================
$engine = {
    param($sync, $opt)

    $backupDir  = $opt.BackupDir
    $logFile    = if ($backupDir) { Join-Path $backupDir 'fix-log.txt' }
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
    function Get-TbProfiles {
        $sidByPath = @{}
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue | ForEach-Object {
            $p = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
            if ($p) { $sidByPath[$p.ToLower()] = $_.PSChildName }
        }
        # every Windows profile folder (ProfileList also finds profiles that are not on C:)
        $userDirs = if ($opt.IsAdmin) {
            @($sidByPath.Keys | Where-Object { Test-Path $_ } | ForEach-Object { Get-Item $_ }) +
            @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue) | Sort-Object FullName -Unique
        } else { @(Get-Item $env:USERPROFILE) }
        $found = @()
        foreach ($u in $userDirs) {
            $tbRoot = Join-Path $u.FullName 'AppData\Roaming\Thunderbird'
            $ini    = Join-Path $tbRoot 'profiles.ini'
            if (-not (Test-Path $ini)) { continue }
            $sid = $sidByPath[$u.FullName.ToLower()]
            if (-not $sid) { $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
            $section = @{}
            foreach ($line in @(Get-Content $ini) + '[end]') {
                if ($line -match '^\[') {
                    if ($section.Path) {
                        $p    = $section.Path.Trim()
                        $full = if ($section.IsRelative -ne '0') { Join-Path $tbRoot ($p -replace '/', '\') } else { $p }
                        if (Test-Path $full) {
                            $found += [pscustomobject]@{
                                User = $u.Name; UserDir = $u.FullName; Path = (Resolve-Path $full).Path; OwnerSid = $sid
                                # who counts as "the user can write": owner, Everyone, Authenticated Users, Users
                                Sids = @($sid, 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545') }
                        }
                    }
                    $section = @{}
                }
                elseif ($line -match '^(\w+)=(.*)$') { $section[$Matches[1]] = $Matches[2] }
            }
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
            $scheme = @{ imap = 'imap'; pop3 = 'mailbox' }[$type]
            $list += [pscustomobject]@{
                Key = "$($pr.Path)|$srv"; ServerKey = $srv; RawType = $type; Email = $email; Server = $hostName
                Type = @{ imap = 'IMAP'; pop3 = 'POP3'; none = 'Local Folders'; movemail = 'Movemail' }[$type]
                Dir = $dir; Profile = $pr; Port = [int]$port; SmtpHost = $smtpHost; SmtpPort = [int]$smtpPort
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
                if ($locked) { $issues += New-Issue 'LOCKED' "กล่องจดหมายเปิดเขียนไม่ได้ (ถูกล็อก/ไม่มีสิทธิ์): $($locked.Count) ไฟล์ ($(Join-Names $locked))" $true }
            }

            foreach ($b in @($mbox | Where-Object { $_.Length -gt 4GB })) {
                $issues += New-Issue 'BIG' "กล่องจดหมาย '$($b.Name)' ใหญ่ $([math]::Round($b.Length / 1GB, 1)) GB - ควร Compact และย้ายอีเมลเก่าไป Archive" $false
            }
        }

        # Receiving / sending: settings and network
        if ($acc.CheckNewOff) {
            $issues += New-Issue 'NOCHECK' 'ปิดการตรวจเมลใหม่อัตโนมัติไว้ (เมลจะไม่เข้าเอง)' $true
        }
        if ($acc.Server -and $acc.Port) {
            switch (Test-Server $acc.Server $acc.Port) {
                'dns'  { $issues += New-Issue 'NET_IN' "หาเซิร์ฟเวอร์รับเมล $($acc.Server) ไม่เจอ (DNS) - ตรวจอินเทอร์เน็ต / ชื่อเซิร์ฟเวอร์" $false }
                'port' { $issues += New-Issue 'NET_IN' "เชื่อมต่อเซิร์ฟเวอร์รับเมล $($acc.Server):$($acc.Port) ไม่ได้ - ตรวจอินเทอร์เน็ต / Firewall / Antivirus" $false }
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
            User = $acc.Profile.User; ProfilePath = $acc.Profile.Path; Size = $size; Issues = $issues; Status = $status }
    }

    function Repair-Account($acc) {
        Log 'STEP' "กำลังแก้ไข: $($acc.Email)"
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
    }

    # Closes Thunderbird cleanly (it saves its files on exit); forces it only after 15 s
    function Stop-Thunderbird {
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
            Add-Type -Namespace TbFix -Name Sqlite -MemberDefinition @'
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open16", CharSet = CharSet.Unicode)] public static extern int Open(string file, out IntPtr db);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close_v2")] public static extern int Close(IntPtr db);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_busy_timeout")] public static extern int BusyTimeout(IntPtr db, int ms);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare16_v2", CharSet = CharSet.Unicode)] public static extern int Prepare(IntPtr db, string sql, int bytes, out IntPtr stmt, IntPtr tail);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step")] public static extern int Step(IntPtr stmt);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_text16")] public static extern IntPtr ColumnText(IntPtr stmt, int col);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize")] public static extern int Finalize(IntPtr stmt);
'@
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
        $tbRunning = [bool](Get-Process thunderbird -ErrorAction SilentlyContinue)
        Prog 3 'กำลังค้นหาโปรไฟล์ Thunderbird...'
        $profiles = @(Get-TbProfiles)   # @() - a single PSCustomObject has no .Count in PowerShell 5.1
        $accounts = @(foreach ($pr in $profiles) { Get-Accounts $pr })
        if (-not $accounts) { Log 'WARN' 'ไม่พบบัญชีอีเมลใน Thunderbird บนเครื่องนี้'; $sync.Results = @(); return }

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
            $accounts = @(foreach ($pr in $profiles) { Get-Accounts $pr })   # prefs.js may have changed
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
            $accounts = @(foreach ($pr in $profiles) { Get-Accounts $pr })
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
$tbExe = @("$env:ProgramFiles\Mozilla Thunderbird\thunderbird.exe", "${env:ProgramFiles(x86)}\Mozilla Thunderbird\thunderbird.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
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
$lnkAll  = New-Object Windows.Forms.LinkLabel
$lnkNone = New-Object Windows.Forms.LinkLabel
foreach ($pair in @(@($lnkAll, 'เลือกทั้งหมด', 832), @($lnkNone, 'ล้างการเลือก', 892))) {
    $pair[0].Text = $pair[1]; $pair[0].Location = New-Object Drawing.Point($pair[2], 16); $pair[0].AutoSize = $true
    $pair[0].Font = F 9; $pair[0].LinkColor = $C.Accent; $pair[0].LinkBehavior = 'HoverUnderline'; $pair[0].BackColor = 'Transparent'
    $listCard.Controls.Add($pair[0])
}
$lnkNone.Left = 952 - 18 - $lnkNone.PreferredWidth
$lnkAll.Left  = $lnkNone.Left - 14 - $lnkAll.PreferredWidth
$lblSummary.Left = $lnkAll.Left - 18 - $lblSummary.Width

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
$script:results = @(); $script:fixedKeys = @(); $script:sync = $null; $script:ps = $null
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
    if ($script:results.Count -eq 0) { $lblEmpty.Text = 'ไม่พบบัญชีอีเมลใน Thunderbird' }
    $first = $lv.Items | Where-Object { $_.Tag.Status -ne 'ok' } | Select-Object -First 1
    if (-not $first -and $lv.Items.Count) { $first = $lv.Items[0] }
    if ($first) { $first.Selected = $true } else { Show-Details $null }
}

function Set-Busy([bool]$busy) {
    foreach ($b in $btnScan, $btnFixSel, $btnFixAll, $btnOpt) { $b.Enabled = -not $busy }
    $btnFixAll.BackColor = if ($busy) { $C.AccentSoft } else { $C.Accent }
    $btnOpt.BackColor    = if ($busy) { Hex '#99C9C4' } else { Hex '#0F766E' }
    $lv.Enabled = -not $busy
    $form.Cursor = if ($busy) { 'AppStarting' } else { 'Default' }
}

function Start-Engine($mode, $keys) {
    Set-Busy $true
    $script:mode = $mode
    $script:backupDir = if ($mode -ne 'scan') {
        Join-Path ([Environment]::GetFolderPath('Desktop')) "Thunderbird-Fix-Backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    $script:sync = [hashtable]::Synchronized(@{
        Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Progress = 0; StatusText = ''; Done = $false; Results = $null; TbRunning = $false
        OptDone = $false; OptSaved = [int64]0; OptWarn = 0 })
    $opt = @{ Mode = $mode; Targets = @($keys); IsAdmin = $isAdmin; BackupDir = $script:backupDir
              RebuildIndex = [bool]$tglIndex.Tag; Defender = [bool]$tglDef.Tag }
    $script:ps = [PowerShell]::Create()
    [void]$script:ps.AddScript($engine).AddArgument($script:sync).AddArgument($opt)
    [void]$script:ps.BeginInvoke()
    $timer.Start()
}

function Start-Fix($keys) {
    if (-not $keys) { return }
    if (Get-Process thunderbird -ErrorAction SilentlyContinue) {
        $a = [Windows.Forms.MessageBox]::Show("Thunderbird กำลังเปิดอยู่ ระบบจะปิด Thunderbird ก่อนเริ่มแก้ไข`r`n`r`nดำเนินการต่อหรือไม่?",
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
            [Windows.Forms.MessageBox]::Show("แก้ไขสำเร็จ $ok บัญชี`r`nยังมีปัญหา $bad บัญชี - คลิกที่บัญชีเพื่อดูสิ่งที่ต้องแก้เอง",
                'Thunderbird Fix', 'OK', 'Warning') | Out-Null
        } else {
            $lblStatus.Text = "แก้ไขเรียบร้อยทั้ง $ok บัญชี  •  เปิด Thunderbird แล้วลองส่ง/รับอีเมลได้เลย"; $lblStatus.ForeColor = $C.Green
            [Windows.Forms.MessageBox]::Show("แก้ไขเรียบร้อยทั้ง $ok บัญชี`r`n`r`nเปิด Thunderbird แล้วลองใช้งาน หากยังพบปัญหาในโฟลเดอร์ใด ให้คลิกขวาที่โฟลเดอร์ > Properties > Repair Folder",
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
        [Windows.Forms.MessageBox]::Show($lblStatus.Text, 'Thunderbird Fix', 'OK', $(if ($script:sync.OptDone -and -not $nW) { 'Information' } else { 'Warning' })) | Out-Null
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
        [Windows.Forms.MessageBox]::Show('ไม่พบบัญชีที่มีปัญหาที่แก้อัตโนมัติได้', 'Thunderbird Fix', 'OK', 'Information') | Out-Null; return }
    Start-Fix $keys
})
$btnFixSel.Add_Click({
    $keys = @($lv.CheckedItems | ForEach-Object { $_.Tag.Key })
    if (-not $keys) {
        [Windows.Forms.MessageBox]::Show('กรุณาติ๊กเลือกบัญชีที่ต้องการแก้ไขก่อน', 'Thunderbird Fix', 'OK', 'Information') | Out-Null; return }
    Start-Fix $keys
})
$btnOpt.Add_Click({
    $a = [Windows.Forms.MessageBox]::Show(
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
$btnBackup.Add_Click({ if ($script:backupDir -and (Test-Path $script:backupDir)) { Start-Process explorer.exe $script:backupDir } })
$btnTB.Add_Click({
    if ($tbExe) { Start-Process $tbExe } else { [Windows.Forms.MessageBox]::Show('ไม่พบ thunderbird.exe', 'Thunderbird Fix') | Out-Null }
})

$form.Add_Shown({ Start-Engine 'scan' @() })
$form.Add_FormClosing({
    if ($script:sync -and -not $script:sync.Done) {
        $_.Cancel = ([Windows.Forms.MessageBox]::Show('ระบบกำลังทำงานอยู่ ต้องการปิดหรือไม่?', 'Thunderbird Fix', 'YesNo', 'Warning') -ne 'Yes')
    }
})

[void]$form.ShowDialog()
$mutex.ReleaseMutex(); $mutex.Dispose()
