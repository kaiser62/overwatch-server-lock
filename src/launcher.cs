// Double-click launcher: unpacks the embedded PowerShell scripts and opens the GUI hidden.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

static class Launcher
{
    [STAThread]
    static void Main()
    {
        try
        {
            string dir = Path.Combine(Path.GetTempPath(), "ow-server-lock");
            Directory.CreateDirectory(dir);
            Assembly asm = Assembly.GetExecutingAssembly();
            foreach (string name in new[] { "ow-lock.ps1", "ow-gui.ps1", "icon.ico" })
            {
                using (Stream src = asm.GetManifestResourceStream(name))
                using (FileStream dst = File.Create(Path.Combine(dir, name)))
                    src.CopyTo(dst);
            }
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" +
                Path.Combine(dir, "ow-gui.ps1") + "\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true
            };
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Overwatch Server Lock", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
