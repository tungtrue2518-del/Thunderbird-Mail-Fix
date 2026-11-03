// Thunderbird Mail Fix - exe launcher.
// The whole PowerShell tool is embedded as the resource "tool.ps1" and runs
// in-process on an STA thread, so the exe is a single self-contained file.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

[assembly: AssemblyTitle("Thunderbird Mail Fix")]
[assembly: AssemblyProduct("Thunderbird Mail Fix")]
[assembly: AssemblyDescription("Scan and fix Mozilla Thunderbird mail accounts")]
// __VERSION__ is filled in by build.ps1 from $AppVersion in Thunderbird-Fix-Tool.ps1
[assembly: AssemblyVersion("__VERSION__.0")]
[assembly: AssemblyFileVersion("__VERSION__.0")]
[assembly: AssemblyInformationalVersion("__VERSION__")]

static class Program
{
    const string Title = "Thunderbird Mail Fix";

    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    static extern int WNetGetConnection(string localName, StringBuilder remoteName, ref int length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int QueryDosDevice(string deviceName, StringBuilder target, int max);

    [STAThread]
    static int Main(string[] args)
    {
        // The manifest asks for nothing (asInvoker); elevate here instead so that pressing "No" on
        // UAC still opens the tool (current user only) rather than doing nothing at all.
        if (!IsAdmin() && !args.Contains("--elevated") && RelaunchElevated())
            return 0;

        int code = Run();
        Environment.Exit(code);   // do not let a background scan keep the process alive
        return code;
    }

    static bool IsAdmin()
    {
        return new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
    }

    static bool RelaunchElevated()
    {
        var exe = RealPath(Assembly.GetExecutingAssembly().Location);
        var psi = new ProcessStartInfo(exe, "--elevated") { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(exe) };
        if (Environment.GetEnvironmentVariable("TBFIX_TEST_NO_RUNAS") != "1") psi.Verb = "runas";
        try { Process.Start(psi); return true; }
        catch (Win32Exception) { return false; }   // 1223: user pressed "No"
    }

    // Elevated processes cannot see the user's mapped network drives or SUBST drives:
    // turn Z:\tool.exe into \\server\share\tool.exe (or the folder behind a SUBST letter).
    static string RealPath(string path)
    {
        if (path.Length < 3 || path.StartsWith(@"\\") || path[1] != ':') return path;
        string drive = path.Substring(0, 2), rest = path.Substring(2);
        var sb = new StringBuilder(1024); int len = sb.Capacity;
        if (WNetGetConnection(drive, sb, ref len) == 0 && sb.Length > 0) return sb.ToString().TrimEnd('\\') + rest;
        sb.Clear();
        if (QueryDosDevice(drive, sb, sb.Capacity) > 0 && sb.ToString().StartsWith(@"\??\"))
            return sb.ToString().Substring(4).TrimEnd('\\') + rest;
        return path;
    }

    static int Run()
    {
        var log = Path.Combine(Path.GetTempPath(), "ThunderbirdMailFix-errors.log");
        try
        {
            string script;
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("tool.ps1"))
            using (var r = new StreamReader(s, Encoding.UTF8))
                script = r.ReadToEnd();

            // Same as "powershell -ExecutionPolicy Bypass": applies to every runspace in this
            // process, including the background one the tool starts for scanning.
            Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass");

            var iss = InitialSessionState.CreateDefault();
            iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
            using (var rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.ApartmentState = ApartmentState.STA;
                rs.ThreadOptions = PSThreadOptions.UseCurrentThread;
                rs.Open();
                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(script);
                    ps.Invoke();
                    bool shown = rs.SessionStateProxy.GetVariable("TbFixUiShown") is bool;
                    if (ps.Streams.Error.Count > 0)
                    {
                        var sb = new StringBuilder();
                        sb.AppendLine(DateTime.Now.ToString("s"));
                        foreach (var e in ps.Streams.Error) sb.AppendLine(e.ToString() + "  @ " + e.InvocationInfo.PositionMessage);
                        File.AppendAllText(log, sb.ToString(), Encoding.UTF8);
                        // the window never appeared: say why instead of silently doing nothing
                        if (!shown)
                            MessageBox.Show("โปรแกรมเปิดไม่สำเร็จ / The tool could not start:\r\n\r\n" +
                                ps.Streams.Error[0].ToString() + "\r\n\r\nรายละเอียด: " + log,
                                Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            try { File.AppendAllText(log, DateTime.Now.ToString("s") + " " + ex + "\r\n", Encoding.UTF8); } catch { }
            MessageBox.Show("โปรแกรมเปิดไม่สำเร็จ / The tool could not start:\r\n\r\n" + ex.Message + "\r\n\r\nรายละเอียด: " + log,
                Title, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
