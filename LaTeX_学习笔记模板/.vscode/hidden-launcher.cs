using System;
using System.Diagnostics;
using System.IO;
using System.Text;
internal static class HiddenLatexLauncher {
    private static string Quote(string value) {
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { result.Append('\\', slashes * 2 + 1).Append(c); }
            else { result.Append('\\', slashes).Append(c); }
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }
    [STAThread]
    private static int Main(string[] args) {
        string root = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));
        try {
            if (args.Length > 1) root = Path.GetFullPath(args[1]);
            string script = Path.Combine(root, ".vscode", "build-latex.ps1");
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            string command = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -ProjectRoot " + Quote(root);
            if (args.Length > 0 && args[0].Length != 0) command += " -MainFile " + Quote(args[0]);
            if (args.Length > 2 && args[2].Length != 0) command += " -TeXBin " + Quote(args[2]);
            if (args.Length > 3) command += " -Mode " + Quote(args[3]);
            ProcessStartInfo info = new ProcessStartInfo(ps, command);
            info.WorkingDirectory = root;
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            using (Process process = Process.Start(info)) {
                process.WaitForExit();
                return process.ExitCode;
            }
        } catch (Exception error) {
            try {
                string build = Path.Combine(root, "build");
                Directory.CreateDirectory(build);
                File.AppendAllText(Path.Combine(build, "launcher-error.log"), DateTime.Now.ToString("s") + " " + error + Environment.NewLine);
            } catch { }
            return 1;
        }
    }
}