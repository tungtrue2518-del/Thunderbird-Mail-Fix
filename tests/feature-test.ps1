param(
    [string]$Tool    = "$PSScriptRoot\..\Thunderbird-Fix-Tool.ps1",
    [string]$Root    = "$env:TEMP\tbfix-feature-test",
    [string]$ShotDir = "$env:TEMP",
    [string]$Build   # path to build.ps1 = test the packaged exe instead of the script
)
<#
    Dry test of every feature on a fake broken profile, driven through the real window
    with UI Automation: scan, auto-fix, POP3 receive test (fake POP3 server), single
    instance, Optimize. Never touches the real Thunderbird, TEMP or Desktop.

      powershell -ExecutionPolicy Bypass -File tests\feature-test.ps1
      powershell -ExecutionPolicy Bypass -File tests\feature-test.ps1 -Build .\build.ps1
#>
$ErrorActionPreference = 'Stop'
$Tool = (Resolve-Path $Tool).Path
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -Name Cap -Namespace Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, string l);
public struct RECT { public int Left, Top, Right, Bottom; }
'@
[Native.Cap]::SetProcessDPIAware() | Out-Null
$results = New-Object System.Collections.Generic.List[string]
function Check($name, [bool]$ok, $detail = '') { $results.Add(('{0}  {1}{2}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { "  ($detail)" }))) }
function Shot($h, $name) {
    $r = New-Object Native.Cap+RECT; [Native.Cap]::GetWindowRect($h, [ref]$r) | Out-Null
    if ($r.Right -le $r.Left) { return }
    $bmp = New-Object Drawing.Bitmap(($r.Right - $r.Left), ($r.Bottom - $r.Top))
    $g = [Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
    [Native.Cap]::PrintWindow($h, $hdc, 2) | Out-Null; $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp.Save("$ShotDir\$name.png"); $bmp.Dispose()
}

# --- fake profile ---------------------------------------------------------------
if (Test-Path $Root) { & icacls.exe "$Root" /reset /T /C /Q | Out-Null; Remove-Item $Root -Recurse -Force }
$tbRoot = "$Root\user\AppData\Roaming\Thunderbird"; $prof = "$tbRoot\Profiles\test.default"
$good  = "$prof\Mail\pop.good-company.com"; $bad = "$prof\Mail\imap.broken-company.com"
$quiet = "$prof\Mail\pop.quiet-company.com"; $local = "$prof\Mail\Local Folders"
New-Item -ItemType Directory -Force $good, $bad, $quiet, $local, "$Root\temp", "$Root\desktop" | Out-Null
Set-Content "$tbRoot\profiles.ini" "[Profile0]`nName=test`nIsRelative=1`nPath=Profiles/test.default`n"

# plain listener (accepts, says nothing) for SMTP/IMAP; port 1 on localhost is closed
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $listener.Start()
$port = $listener.LocalEndpoint.Port
# fake POP3 server: password "secret" logs in (3 messages waiting), anything else gets -ERR [AUTH]
$popListener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $popListener.Start()
$popPort = $popListener.LocalEndpoint.Port
$popServer = [PowerShell]::Create().AddScript({
    param($l)
    while ($true) {
        try { $c = $l.AcceptTcpClient() } catch { break }
        try {
            $s = $c.GetStream(); $s.ReadTimeout = 20000
            $r = New-Object IO.StreamReader($s); $w = New-Object IO.StreamWriter($s); $w.NewLine = "`r`n"; $w.AutoFlush = $true
            $w.WriteLine('+OK fake POP3 ready')
            while ($null -ne ($line = $r.ReadLine())) {
                if ($line -like 'USER *') { $w.WriteLine('+OK') }
                elseif ($line -eq 'PASS secret') { $w.WriteLine('+OK logged in') }
                elseif ($line -like 'PASS *') { $w.WriteLine('-ERR [AUTH] Authentication failed') }
                elseif ($line -eq 'STAT') { $w.WriteLine('+OK 3 4096') }
                elseif ($line -eq 'QUIT') { $w.WriteLine('+OK bye'); break }
                else { $w.WriteLine('-ERR unknown') }
            }
        } catch {}
        $c.Close()
    }
}).AddArgument($popListener)
[void]$popServer.BeginInvoke()

Set-Content "$prof\prefs.js" @"
user_pref("mail.accountmanager.accounts", "account1,account2,account3,account4");
user_pref("mail.smtp.defaultserver", "smtp1");
user_pref("mail.smtpserver.smtp1.hostname", "127.0.0.1");
user_pref("mail.smtpserver.smtp1.port", $port);
user_pref("mail.account.account1.server", "server1");
user_pref("mail.account.account1.identities", "id1");
user_pref("mail.identity.id1.useremail", "sales@good-company.com");
user_pref("mail.server.server1.type", "pop3");
user_pref("mail.server.server1.hostname", "127.0.0.1");
user_pref("mail.server.server1.port", $popPort);
user_pref("mail.server.server1.userName", "sales");
user_pref("mail.server.server1.leave_on_server", true);
user_pref("mail.server.server1.directory-rel", "[ProfD]Mail/pop.good-company.com");
user_pref("mail.account.account2.server", "server2");
user_pref("mail.account.account2.identities", "id2");
user_pref("mail.identity.id2.useremail", "process@broken-company.com");
user_pref("mail.server.server2.type", "imap");
user_pref("mail.server.server2.hostname", "localhost");
user_pref("mail.server.server2.port", $port);
user_pref("mail.server.server2.directory-rel", "[ProfD]Mail/imap.broken-company.com");
user_pref("mail.account.account3.server", "server3");
user_pref("mail.account.account3.identities", "id3");
user_pref("mail.identity.id3.useremail", "quiet@quiet-company.com");
user_pref("mail.server.server3.type", "pop3");
user_pref("mail.server.server3.hostname", "127.0.0.1");
user_pref("mail.server.server3.port", 1);
user_pref("mail.server.server3.check_new_mail", false);
user_pref("mail.server.server3.directory-rel", "[ProfD]Mail/pop.quiet-company.com");
user_pref("mail.account.account4.server", "server4");
user_pref("mail.server.server4.type", "none");
user_pref("mail.server.server4.directory-rel", "[ProfD]Mail/Local Folders");
"@
Set-Content "$prof\logins.json" '{"logins":[{"hostname":"mailbox://127.0.0.1"}]}'

# broken IMAP account: read-only, 0-byte index, compact leftover, deny-write
Set-Content "$good\Inbox" "From - test`nhello"; Set-Content "$good\Inbox.msf" 'x'
Set-Content "$bad\Inbox" "From - test`nhello"; New-Item "$bad\Inbox.msf" -ItemType File | Out-Null
Set-Content "$bad\Sent" "From - test`nhi"; (Get-Item "$bad\Sent").IsReadOnly = $true
Set-Content "$bad\nstmp" 'leftover'
Set-Content "$bad\Trash" "From - x"
& icacls.exe "$bad\Trash" /deny "*$([Security.Principal.WindowsIdentity]::GetCurrent().User.Value):(W)" | Out-Null
Set-Content "$Root\temp\nsmail-1.tmp" 'compose leftover'

# quiet POP3 account: unreachable, check-new-mail off, damaged popstate.dat, filters
Set-Content "$quiet\Inbox" "From - test`nhello"
Set-Content "$quiet\popstate.dat" "# POP3 State File`n*127.0.0.1 quiet`nk UIDL1 1700000000`n@@garbage@@"
Set-Content "$quiet\msgFilterRules.dat" @'
version="9"
logging="no"
name="Delete newsletters"
enabled="yes"
type="17"
action="Delete"
condition="AND (subject,contains,news)"
name="Old rule"
enabled="no"
type="17"
action="Move to folder"
actionValue="mailbox://nobody@Local%20Folders/Archive"
condition="AND (from,contains,x)"
'@

# Local Folders: Outbox (1 waiting, 1 deleted) and Junk (2 recent live, 1 recent deleted, 1 old)
Set-Content "$local\Unsent Messages" "From - a`nX-Mozilla-Status: 0001`n`nwaiting`nFrom - b`nX-Mozilla-Status: 0009`n`nsent"
$inv = [Globalization.CultureInfo]::InvariantCulture
$now = (Get-Date).ToString('ddd MMM d HH:mm:ss yyyy', $inv); $old = (Get-Date).AddDays(-40).ToString('ddd MMM d HH:mm:ss yyyy', $inv)
Set-Content "$local\Junk" "From - $old`nX-Mozilla-Status: 0001`n`nold`nFrom - $now`nX-Mozilla-Status: 0001`n`ncustomer 1`nFrom - $now`nX-Mozilla-Status: 0009`n`ndeleted`nFrom - $now`nX-Mozilla-Status: 0000`n`ncustomer 2"

# --- databases / settings for the Optimize test ---------------------------------
Add-Type -Namespace T -Name Sql -MemberDefinition @'
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open16", CharSet = CharSet.Unicode)] public static extern int Open(string f, out IntPtr db);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_exec")] public static extern int Exec(IntPtr db, byte[] sql, IntPtr cb, IntPtr arg, IntPtr err);
[DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close_v2")] public static extern int Close(IntPtr db);
'@
function New-Db($file, $sql) {
    $db = [IntPtr]::Zero; [void][T.Sql]::Open($file, [ref]$db)
    [void][T.Sql]::Exec($db, [Text.Encoding]::UTF8.GetBytes($sql + "`0"), [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    [void][T.Sql]::Close($db)
}
$filler = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<20000) INSERT INTO t SELECT i, hex(randomblob(100)) FROM n;"
New-Db "$prof\places.sqlite" "CREATE TABLE t(a,b); $filler DELETE FROM t;"
New-Db "$prof\abook.sqlite"  "CREATE TABLE cards(name); INSERT INTO cards VALUES('Somchai');"
[IO.File]::WriteAllBytes("$prof\global-messages-db.sqlite", [byte[]](1..4096 | ForEach-Object { $_ % 251 }))
[IO.File]::WriteAllBytes("$prof\history.sqlite", [byte[]](1..4096 | ForEach-Object { $_ % 13 }))
Set-Content "$prof\xulstore.json" '{"broken": '
Set-Content "$prof\folderCache.json" '{"ok": true}'
& fsutil.exe file createnew "$quiet\Junk" 330301440 | Out-Null
$placesBefore = (Get-Item "$prof\places.sqlite").Length

# --- patched copy of the tool: fake Thunderbird process + fake Desktop + own single-instance name ---
$text = [IO.File]::ReadAllText($Tool, [Text.Encoding]::UTF8) -replace 'Get-Process thunderbird', 'Get-Process tb_test_none' `
    -replace "\[Environment\]::GetFolderPath\('Desktop'\)", "'$Root\desktop'" `
    -replace 'ThunderbirdMailFix-SingleInstance', 'ThunderbirdMailFix-DryTest'
[IO.File]::WriteAllText("$Root\tool.ps1", $text, (New-Object Text.UTF8Encoding($true)))
$env:USERPROFILE = "$Root\user"; $env:TEMP = "$Root\temp"

# engine-only checks first
$ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
$eng = $ast.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$engine' }, $true) | Select-Object -First 1
$engineSb = [scriptblock]::Create($eng.Right.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
function Run-Engine($opt) {
    $s = [hashtable]::Synchronized(@{ Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'; Progress = 0; StatusText = ''; Done = $false
        Results = $null; TbRunning = $false; OptDone = $false; OptSaved = [int64]0; OptWarn = 0; LoginResult = $null })
    $ps = [PowerShell]::Create(); [void]$ps.AddScript($engineSb).AddArgument($s).AddArgument($opt)
    [void]$ps.BeginInvoke(); while (-not $s.Done) { Start-Sleep -Milliseconds 100 }
    if ($ps.Streams.Error.Count) { $ps.Streams.Error | ForEach-Object { $results.Add("ENGINE ERROR: $_ @ $($_.InvocationInfo.ScriptLineNumber)") } }
    $s
}
$s = Run-Engine @{ Mode = 'scan'; Targets = @(); IsAdmin = $false }
function Codes($email) { @(($s.Results | Where-Object Email -eq $email).Issues | ForEach-Object Code) }
Check 'scan: good POP3 account is normal'              (($s.Results | Where-Object Email -eq 'sales@good-company.com').Status -eq 'ok')
$badCodes = Codes 'process@broken-company.com'
Check 'scan: broken account (RO, nstmp, msf, ACL, lock)' (-not (Compare-Object @('READONLY','NSTMP','MSF','NOWRITE','LOCKED') $badCodes | Where-Object SideIndicator -eq '<=')) ($badCodes -join ',')
$quietCodes = Codes 'quiet@quiet-company.com'
Check 'scan: quiet POP3 (nocheck, net, popstate, leave, filter)' (-not (Compare-Object @('NOCHECK','NET_IN','POPSTATE','POP_LEAVE','FILTER') $quietCodes | Where-Object SideIndicator -eq '<=')) ($quietCodes -join ',')
$localCodes = Codes 'Local Folders'
$junk = ($s.Results | Where-Object Email -eq 'Local Folders').Issues | Where-Object Code -eq 'JUNK'
Check 'scan: Local Folders Junk (2 recent) + Outbox'     (($localCodes -contains 'OUTBOX') -and $junk.Text -match ' 2 ') ($localCodes -join ',')
$s = Run-Engine @{ Mode = 'login'; Login = @{ Server = '127.0.0.1'; Port = $popPort; SocketType = '0'; UserName = 'sales'; Password = 'secret' } }
Check 'login: right password -> OK, 3 messages'          ($s.LoginResult.Ok -and $s.LoginResult.Summary -match ' 3 ') $s.LoginResult.Summary
$s = Run-Engine @{ Mode = 'login'; Login = @{ Server = '127.0.0.1'; Port = $popPort; SocketType = '0'; UserName = 'sales'; Password = 'wrong' } }
Check 'login: wrong password -> explained'               ((-not $s.LoginResult.Ok) -and $s.LoginResult.Text -match 'AUTH') $s.LoginResult.Summary

# --- the real window ------------------------------------------------------------
if ($Build) { & powershell -NoProfile -ExecutionPolicy Bypass -File $Build -Script "$Root\tool.ps1" -Out "$Root\test.exe" | Out-Null }
function Start-Tool {
    if ($Build) { Start-Process "$Root\test.exe" -PassThru -ArgumentList '--elevated' }   # skip self-elevation: no UAC in tests
    else { Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
            "iex ([IO.File]::ReadAllText('$Root\tool.ps1', [Text.Encoding]::UTF8))" }
}
$uia = [Windows.Automation.AutomationElement]
function Find-Win($procId, $name, $timeout = 30) {
    for ($i = 0; $i -lt $timeout * 2; $i++) {
        $tops = @($uia::RootElement.FindAll('Children', (New-Object Windows.Automation.PropertyCondition($uia::ProcessIdProperty, [int]$procId))))
        $w = $tops | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
        if (-not $w) {   # dialogs owned by the main window are listed under it
            $winCond = New-Object Windows.Automation.PropertyCondition($uia::ControlTypeProperty, [Windows.Automation.ControlType]::Window)
            $w = $tops | ForEach-Object { $_.FindAll('Children', $winCond) } | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
        }
        if ($w) { return $w }
        Start-Sleep -Milliseconds 500
    }
    $null
}
function Click($win, $name) {
    $b = $win.FindAll('Descendants', (New-Object Windows.Automation.PropertyCondition($uia::NameProperty, $name))) |
        Where-Object { $_.Current.NativeWindowHandle -ne 0 } | Select-Object -First 1
    if ($b) { [Native.Cap]::PostMessage([IntPtr]$b.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }   # BM_CLICK
    [bool]$b
}
function Wait-Exit($proc, $sec) { for ($i = 0; $i -lt $sec * 4; $i++) { if ($proc.HasExited) { return $true }; Start-Sleep -Milliseconds 250 }; $proc.HasExited }

$p = Start-Tool
try {
    $main = Find-Win $p.Id 'Thunderbird Mailbox Fix Tool'
    Check 'window opens' ([bool]$main)
    if (-not $main) { throw 'window did not open' }
    $h = [IntPtr]$main.Current.NativeWindowHandle
    Start-Sleep -Seconds 8
    Shot $h 'feature-1-scan'

    [void](Click $main 'แก้ไขอัตโนมัติทุกบัญชีที่มีปัญหา')
    $mb = Find-Win $p.Id 'Thunderbird Fix' 120
    Check 'auto-fix finishes with a result message' ([bool]$mb)
    Shot $h 'feature-2-fixed'
    if ($mb) { [void](Click $mb 'OK') }; Start-Sleep -Seconds 1

    # receive test from the window: select the first account (sales@ - fake POP3), right then wrong password
    $lvEl = $main.FindAll('Descendants', [Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.ClassName -like '*SysListView32*' } | Select-Object -First 1
    $lvH = [IntPtr]$lvEl.Current.NativeWindowHandle
    $lp = [IntPtr]((44 -shl 16) -bor 120)   # first row, below the column header
    [Native.Cap]::PostMessage($lvH, 0x201, [IntPtr]1, $lp) | Out-Null; [Native.Cap]::PostMessage($lvH, 0x202, [IntPtr]0, $lp) | Out-Null
    Start-Sleep -Seconds 1
    foreach ($try in @(@('secret', 'feature-3-login-ok'), @('wrong', 'feature-4-login-bad'))) {
        [void](Click $main 'ทดสอบรับเมล')
        $dlg = Find-Win $p.Id 'ทดสอบการรับเมล' 15
        $ok = [bool]$dlg
        if ($dlg) {
            $edit = $dlg.FindAll('Descendants', [Windows.Automation.Condition]::TrueCondition) |
                Where-Object { $_.Current.ClassName -like '*EDIT*' } | Select-Object -First 1
            [Native.Cap]::SendMessage([IntPtr]$edit.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, $try[0]) | Out-Null
            [void](Click $dlg 'ทดสอบ')
            $res = Find-Win $p.Id 'ทดสอบรับเมล - sales@good-company.com' 30
            $ok = [bool]$res
            if ($res) { Start-Sleep -Milliseconds 500; Shot ([IntPtr]$res.Current.NativeWindowHandle) "$($try[1])-box"; [void](Click $res 'OK') }
        }
        Check "window: receive test with '$($try[0])' shows a result" $ok
        Start-Sleep -Milliseconds 500
    }

    # single instance: a second copy must bring the first forward and quit
    $p2 = Start-Tool
    Check 'second copy exits, first stays open' ((Wait-Exit $p2 10) -and -not $p.HasExited)
    Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue

    # Optimize
    [void](Click $main 'Optimize')
    $confirm = Find-Win $p.Id 'Thunderbird Fix - Optimize' 20
    if ($confirm) { [void](Click $confirm 'Yes') }
    $mb2 = Find-Win $p.Id 'Thunderbird Fix' 120
    Check 'Optimize finishes with a result message' ([bool]$mb2)
    Shot $h 'feature-5-optimize'
    if ($mb2) { [void](Click $mb2 'OK') }
}
finally {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    $listener.Stop(); $popListener.Stop()
    Check 'fix: Thunderbird temp file removed'   (@(Get-ChildItem "$Root\temp" -Filter 'nsmail*').Count -eq 0)
    Check 'fix: read-only cleared'               (-not (Get-Item "$bad\Sent").IsReadOnly)
    Check 'fix: deny-write permission repaired'  $(try { [IO.File]::Open("$bad\Trash", 'Open', 'ReadWrite', 'ReadWrite').Close(); $true } catch { $false })
    Check 'fix: check-new-mail turned back on'   ((Select-String -Path "$prof\prefs.js" -Pattern 'server3.check_new_mail", true').Count -eq 1)
    Check 'fix: popstate.dat moved to backup'    ((-not (Test-Path "$quiet\popstate.dat")) -and @(Get-ChildItem "$Root\desktop" -Recurse -Filter 'popstate.dat').Count -eq 1)
    Check 'mail content untouched'               ((Get-Content "$bad\Inbox") -join ' ' -eq 'From - test hello' -and (Select-String -Path "$local\Junk" -Pattern '^customer').Count -eq 2)
    Check 'optimize: bloated database compacted' ((Get-Item "$prof\places.sqlite").Length -lt $placesBefore / 10) "$([int]($placesBefore/1KB)) KB -> $([int]((Get-Item "$prof\places.sqlite").Length/1KB)) KB"
    Check 'optimize: broken search db moved'     ((-not (Test-Path "$prof\global-messages-db.sqlite")) -and @(Get-ChildItem "$Root\desktop" -Recurse -Filter 'global-messages-db.sqlite').Count -ge 1)
    Check 'optimize: broken history kept + copy' ((Test-Path "$prof\history.sqlite") -and @(Get-ChildItem "$Root\desktop" -Recurse -Filter 'history.sqlite.damaged').Count -ge 1)
    Check 'optimize: broken xulstore.json moved' (-not (Test-Path "$prof\xulstore.json"))
    Check 'optimize: auto-compact turned on'     ((Select-String -Path "$prof\prefs.js" -Pattern 'mail.purge.ask", false').Count -eq 1)
    $errLog = "$Root\temp\ThunderbirdMailFix-errors.log"
    Check 'no runtime errors logged'             (-not (Test-Path $errLog)) $(if (Test-Path $errLog) { (Get-Content $errLog -Raw).Substring(0, 300) })
    Remove-Item "$quiet\Junk" -Force -ErrorAction SilentlyContinue
    ''
    '================ RESULTS ================'
    $results
    ''
    "passed $(@($results | Where-Object { $_ -like 'PASS*' }).Count) / $(@($results | Where-Object { $_ -like 'PASS*' -or $_ -like 'FAIL*' }).Count)"
}
