// Thunderbird Mail Fix - exe launcher.
// The whole PowerShell tool is embedded as the resource "tool.ps1" and runs
// in-process on an STA thread, so the exe is a single self-contained file.
using System;
using System.IO;
using System.Reflection;
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
    [STAThread]
    static int Main()
    {
        const string title = "Thunderbird Mail Fix";
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
                    if (ps.Streams.Error.Count > 0)
                    {
                        var log = Path.Combine(Path.GetTempPath(), "ThunderbirdMailFix-errors.log");
                        var sb = new StringBuilder();
                        sb.AppendLine(DateTime.Now.ToString("s"));
                        foreach (var e in ps.Streams.Error) sb.AppendLine(e.ToString() + "  @ " + e.InvocationInfo.PositionMessage);
                        File.AppendAllText(log, sb.ToString(), Encoding.UTF8);
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("โปรแกรมเกิดข้อผิดพลาด / Unexpected error:\r\n\r\n" + ex.Message, title,
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
