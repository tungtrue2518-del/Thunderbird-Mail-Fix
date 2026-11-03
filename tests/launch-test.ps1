param([string]$Tool, [string]$Root, [string]$ShotDir, [string]$Build)
# Dry test for "does not open" / "cannot find Thunderbird" / "stuck until restart".
# Everything runs against fake profiles under $Root; the real Thunderbird is never touched.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type -Name Cap -Namespace Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
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
$uia = [Windows.Automation.AutomationElement]
function Find-Win($procId, $name, $timeout = 20) {
    # search the process's own top-level windows (searching the whole desktop by name proved unreliable)
    # dialogs owned by the main window are listed under it, so look one level down too
    for ($i = 0; $i -lt $timeout * 2; $i++) {
        $tops = @($uia::RootElement.FindAll('Children', (New-Object Windows.Automation.PropertyCondition($uia::ProcessIdProperty, [int]$procId))))
        $w = $tops | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
        if (-not $w) {
            $winCond = New-Object Windows.Automation.PropertyCondition($uia::ControlTypeProperty, [Windows.Automation.ControlType]::Window)
            $w = $tops | ForEach-Object { $_.FindAll('Children', $winCond) } | Where-Object { $_.Current.Name -eq $name } | Select-Object -First 1
        }
        if ($w) { return $w }
        Start-Sleep -Milliseconds 500
    }
    $null
}
function Win-List($procId) { ($uia::RootElement.FindAll('Children', (New-Object Windows.Automation.PropertyCondition($uia::ProcessIdProperty, [int]$procId))) | ForEach-Object { "'$($_.Current.Name)'" }) -join ',' }
function Click($win, $name) {
    $b = $win.FindAll('Descendants', (New-Object Windows.Automation.PropertyCondition($uia::NameProperty, $name))) |
        Where-Object { $_.Current.NativeWindowHandle -ne 0 } | Select-Object -First 1
    if ($b) { [Native.Cap]::PostMessage([IntPtr]$b.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
    [bool]$b
}
function Wait-Exit($proc, $sec) { for ($i = 0; $i -lt $sec * 4; $i++) { if ($proc.HasExited) { return $true }; Start-Sleep -Milliseconds 250 }; $proc.HasExited }

# --- fake profiles ----------------------------------------------------------------
if (Test-Path $Root) { & icacls.exe "$Root" /reset /T /C /Q | Out-Null; Remove-Item $Root -Recurse -Force }
$user = "$Root\user"
function New-Prof($dir, $email, $host_ = '127.0.0.1') {
    New-Item -ItemType Directory -Force "$dir\Mail\acc" | Out-Null
    Set-Content "$dir\Mail\acc\Inbox" "From - x`nhello"
    Set-Content "$dir\prefs.js" @"
user_pref("mail.accountmanager.accounts", "account1");
user_pref("mail.account.account1.server", "server1");
user_pref("mail.account.account1.identities", "id1");
user_pref("mail.identity.id1.useremail", "$email");
user_pref("mail.server.server1.type", "imap");
user_pref("mail.server.server1.hostname", "$host_");
user_pref("mail.server.server1.port", 1);
user_pref("mail.server.server1.directory-rel", "[ProfD]Mail/acc");
"@
}
# 1. Microsoft Store layout  2. no profiles.ini  3. absolute path with "/" and %VAR%  4. Portable (picked by hand)
$store = "$user\AppData\Local\Packages\Mozilla.Thunderbird_ab12cd34\LocalCache\Roaming\Thunderbird"
New-Prof "$store\Profiles\store.default" 'store@example.com'
$env:TBFIX_TESTROOT = $Root
Set-Content "$store\profiles.ini" "[Profile0]`nName=store`nIsRelative=1`nPath=Profiles/store.default`n`n[Profile1]`nName=abs`nIsRelative=0`nPath=%TBFIX_TESTROOT%/abs/profile`n"
New-Prof "$Root\abs\profile" 'abs@example.com'
New-Prof "$user\AppData\Roaming\Thunderbird\Profiles\noini.default" 'noini@example.com'
New-Prof "$Root\ThunderbirdPortable\Data\profile" 'portable@example.com'
# a slow account (black-hole address) so a scan takes several seconds - for the "close while scanning" test
New-Prof "$Root\slow\profile" 'slow@example.com' '10.255.255.1'
New-Item -ItemType Directory -Force "$Root\temp", "$Root\desktop" | Out-Null

# --- patched tool: fake Thunderbird process name, fake Desktop, own single-instance name ----
$text = [IO.File]::ReadAllText($Tool, [Text.Encoding]::UTF8) -replace 'Get-Process thunderbird', 'Get-Process tb_test_none' `
    -replace "\[Environment\]::GetFolderPath\('Desktop'\)", "'$Root\desktop'" `
    -replace 'ThunderbirdMailFix-SingleInstance', 'ThunderbirdMailFix-DryTest'
New-Item -ItemType Directory -Force "$Root\tool" | Out-Null
$toolPs1 = "$Root\tool\Thunderbird-Fix-Tool.ps1"
[IO.File]::WriteAllText($toolPs1, $text, (New-Object Text.UTF8Encoding($true)))
$env:USERPROFILE = $user; $env:TEMP = "$Root\temp"

$ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
$eng = $ast.FindAll({ $args[0] -is [Management.Automation.Language.AssignmentStatementAst] -and $args[0].Left.Extent.Text -eq '$engine' }, $true) | Select-Object -First 1
$engineSb = [scriptblock]::Create($eng.Right.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
function Run-Engine($opt) {
    $s = [hashtable]::Synchronized(@{ Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'; Progress = 0; StatusText = ''; Done = $false
        Results = $null; TbRunning = $false; OptDone = $false; OptSaved = [int64]0; OptWarn = 0; LoginResult = $null })
    $ps = [PowerShell]::Create(); [void]$ps.AddScript($engineSb).AddArgument($s).AddArgument($opt)
    [void]$ps.BeginInvoke(); while (-not $s.Done) { Start-Sleep -Milliseconds 100 }
    $item = $null; $script:engineLog = @(); while ($s.Queue.TryDequeue([ref]$item)) { $script:engineLog += "[$($item[0])] $($item[1])" }
    if ($ps.Streams.Error.Count) { $ps.Streams.Error | ForEach-Object { $results.Add("ENGINE ERROR: $_ @ $($_.InvocationInfo.ScriptLineNumber)") } }
    $s
}

# ================= detection =================
$s = Run-Engine @{ Mode = 'scan'; Targets = @(); IsAdmin = $false; ExtraProfiles = @("$Root\ThunderbirdPortable\Data\profile") }
$emails = @($s.Results | ForEach-Object { $_.Email })
Check '1 Microsoft Store profile found'            ($emails -contains 'store@example.com')
Check '2 profile without profiles.ini found'       ($emails -contains 'noini@example.com')
Check '3 absolute path with / and %VAR% found'     ($emails -contains 'abs@example.com')
Check '4 Thunderbird Portable (picked) found'      ($emails -contains 'portable@example.com')

# ================= stuck processes =================
# a windowless process holding the profile lock (what a hung Thunderbird looks like) + another holding the Inbox
$noini = "$user\AppData\Roaming\Thunderbird\Profiles\noini.default"
$holdLock = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command',
    "`$f = [IO.File]::Open('$noini\parent.lock', 'OpenOrCreate', 'ReadWrite', 'None'); Start-Sleep 600"
$holdInbox = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command',
    "`$f = [IO.File]::Open('$store\Profiles\store.default\Mail\acc\Inbox', 'Open', 'ReadWrite', 'None'); Start-Sleep 600"
'waiting 62 s (a Thunderbird younger than 60 s may still be starting up, so it is not called stuck)...'
Start-Sleep -Seconds 62
$s = Run-Engine @{ Mode = 'scan'; Targets = @(); IsAdmin = $false }
$noiniRes = $s.Results | Where-Object Email -eq 'noini@example.com'
$storeRes = $s.Results | Where-Object Email -eq 'store@example.com'
$stuckIssue = $noiniRes.Issues | Where-Object Code -eq 'TB_STUCK'
Check '5a stuck background process detected'      ([bool]$stuckIssue) "$($stuckIssue.Text)"
$lockIssue = $storeRes.Issues | Where-Object Code -eq 'LOCKED'
Check '6 locked mail file names the program'       ($lockIssue.Text -match 'powershell') "$($lockIssue.Text)"
$s = Run-Engine @{ Mode = 'fix'; Targets = @($noiniRes.Key); IsAdmin = $false; BackupDir = "$Root\desktop\fix1" }
$holdLock.Refresh()
Check '5b fix ends the stuck process (no restart)' (Wait-Exit $holdLock 5)
$after = $s.Results | Where-Object Email -eq 'noini@example.com'
Check '5c rescan: no longer stuck'                 (-not ($after.Issues | Where-Object Code -eq 'TB_STUCK'))
Stop-Process -Id $holdInbox.Id -Force -ErrorAction SilentlyContinue

# ================= opening the program =================
function Start-Tool([string]$exe, [string[]]$exeArgs) {
    if ($exe) { Start-Process $exe -PassThru -ArgumentList $exeArgs }
    else { Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
            "iex ([IO.File]::ReadAllText('$toolPs1', [Text.Encoding]::UTF8))" }
}
# 7. a previous copy stuck in the background (holds the single-instance lock, no window)
New-Item -ItemType Directory -Force "$Root\holder" | Out-Null
Set-Content "$Root\holder\Thunderbird-Fix-Tool.ps1" "`$m = New-Object Threading.Mutex(`$true, 'ThunderbirdMailFix-DryTest'); Start-Sleep 600"
$stale = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$Root\holder\Thunderbird-Fix-Tool.ps1"
Start-Sleep -Seconds 2
$p = Start-Tool
$ask = Find-Win $p.Id 'Thunderbird Mail Fix' 20
Check '7a stale copy: asks to end it'              ([bool]$ask)
if ($ask) { Shot ([IntPtr]$ask.Current.NativeWindowHandle) 'launch-7-stale'; [void](Click $ask 'Yes') }
$main = Find-Win $p.Id 'Thunderbird Mailbox Fix Tool' 25
$p.Refresh()
Check '7b stale copy ended, tool opens'            ([bool]$main -and (Wait-Exit $stale 3)) "windows=$(Win-List $p.Id) toolExited=$($p.HasExited) staleExited=$($stale.HasExited)"
# 8. already open: a second start must bring the first one forward and quit
$p2 = Start-Tool
Check '8 second start exits, first stays open'     ((Wait-Exit $p2 10) -and -not $p.HasExited)
Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue
# 14. close normally (after the scan) -> process ends
Start-Sleep -Seconds 4
if ($main) { $main.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close() }
$c14 = Find-Win $p.Id 'Thunderbird Fix' 3
if ($c14) { [void](Click $c14 'Yes') }
Check '14 closing the window ends the process'     (Wait-Exit $p 8) "windows=$(Win-List $p.Id)"
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue

# 12/13. close in the middle of a slow scan -> confirm -> process must not linger (old "stuck until restart")
function Test-CloseWhileBusy($label, $exe, $exeArgs) {
    # a) the user clicks X during a scan: a visible confirm dialog, Yes -> the process ends
    $pp = Start-Tool $exe $exeArgs
    $w = Find-Win $pp.Id 'Thunderbird Mailbox Fix Tool' 25
    if (-not $w) { Check "$label (X button)" $false 'window did not open'; Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue; return }
    Start-Sleep -Milliseconds 1000
    $w.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()   # = clicking X (UserClosing)
    $c = Find-Win $pp.Id 'Thunderbird Fix' 10
    if ($c) { Shot ([IntPtr]$c.Current.NativeWindowHandle) "launch-close-confirm"; [void](Click $c 'Yes') }
    Check "$label (X button)" ([bool]$c -and (Wait-Exit $pp 6)) $(if ($c) { 'confirm dialog shown, answered Yes' } else { 'no confirm dialog appeared' })
    Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue
    # b) Task Manager / Windows shutdown during a scan: no question, the process ends at once
    $pp = Start-Tool $exe $exeArgs
    $w = Find-Win $pp.Id 'Thunderbird Mailbox Fix Tool' 25
    if (-not $w) { Check "$label (shutdown)" $false 'window did not open'; Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue; return }
    Start-Sleep -Milliseconds 1000
    [Native.Cap]::PostMessage([IntPtr]$w.Current.NativeWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Check "$label (shutdown)" (Wait-Exit $pp 6)
    Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue
}
# make scans slow: only the black-hole account is visible
Remove-Item "$user\AppData\Roaming\Thunderbird", "$user\AppData\Local\Packages" -Recurse -Force
New-Prof "$user\AppData\Roaming\Thunderbird\Profiles\slow.default" 'slow@example.com' '10.255.255.1'
Test-CloseWhileBusy '13 script: close during scan, process ends' $null $null

if ($Build) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Build -Script $toolPs1 -Out "$Root\tool\test.exe" | Out-Null
    Test-CloseWhileBusy '12 exe: close during scan, process ends' "$Root\tool\test.exe" @('--elevated')

    # 9/10. start from a SUBST drive (behaves like a mapped network drive for elevation)
    $letter = (68..90 | ForEach-Object { [char]$_ } | Where-Object { -not (Test-Path "${_}:\") } | Select-Object -Last 1)
    & subst.exe "${letter}:" "$Root\tool" | Out-Null
    $env:TBFIX_TEST_NO_RUNAS = '1'
    try {
        $before = @(Get-Process test -ErrorAction SilentlyContinue | ForEach-Object Id)
        $launcher = Start-Process "${letter}:\test.exe" -PassThru
        Start-Sleep -Seconds 6
        $child = Get-Process test -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id -and $_.Id -ne $launcher.Id } | Select-Object -First 1
        $cmd = if ($child) { (Get-CimInstance Win32_Process -Filter "ProcessId=$($child.Id)").CommandLine }
        Check '9 exe on SUBST drive relaunches with real path' ($child -and $cmd -like "*$Root\tool\test.exe*--elevated*") "$cmd"
        if ($child) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }

        $before = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ForEach-Object ProcessId)
        $first = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "${letter}:\Thunderbird-Fix-Tool.ps1"
        Start-Sleep -Seconds 8
        $kid = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $before -notcontains $_.ProcessId -and $_.ProcessId -ne $first.Id } |
            Where-Object { $_.CommandLine -like '*Thunderbird-Fix-Tool.ps1*' } | Select-Object -First 1
        Check '10 script on SUBST drive relaunches with real path' ($kid -and $kid.CommandLine -like "*$Root\tool\Thunderbird-Fix-Tool.ps1*") "$($kid.CommandLine)"
        if ($kid) { Stop-Process -Id $kid.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $first.Id -Force -ErrorAction SilentlyContinue
    } finally { $env:TBFIX_TEST_NO_RUNAS = $null; & subst.exe "${letter}:" /d | Out-Null }

    # 11. the exe cannot start (broken script inside) -> must show an error, not silently do nothing
    Set-Content "$Root\tool\broken.ps1" "throw 'simulated start-up failure'" -Encoding UTF8
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Build -Script "$Root\tool\broken.ps1" -Out "$Root\tool\broken.exe" | Out-Null
    $b = Start-Process "$Root\tool\broken.exe" -PassThru -ArgumentList '--elevated'
    $err = Find-Win $b.Id 'Thunderbird Mail Fix' 15
    Check '11 exe start-up failure shows an error'      ([bool]$err)
    if ($err) { Shot ([IntPtr]$err.Current.NativeWindowHandle) 'launch-11-error'; [void](Click $err 'OK') }
    Stop-Process -Id $b.Id -Force -ErrorAction SilentlyContinue
}

Stop-Process -Id $holdLock.Id, $stale.Id -Force -ErrorAction SilentlyContinue
''
'================ RESULTS ================'
$results
''
"passed $(@($results | Where-Object { $_ -like 'PASS*' }).Count) / $(@($results | Where-Object { $_ -like 'PASS*' -or $_ -like 'FAIL*' }).Count)"
