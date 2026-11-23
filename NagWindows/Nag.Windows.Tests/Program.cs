using System.Drawing.Imaging;
using Nag.Core;
using Nag.Windows;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;

internal static class Program
{
    static IEnumerable<Control> Descendants(Control root)
    {
        foreach (Control child in root.Controls)
        { yield return child; foreach (var nested in Descendants(child)) yield return nested; }
    }
    static Button Find(Form form, string text) => Descendants(form).OfType<Button>().First(b => b.Text == text);
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); Console.WriteLine("PASS " + message); }
    [STAThread]
    static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Contains("--lock-target"))
        {
            using var target = new Form { Text = "Nag disposable lock target", Size = new(300, 220) };
            using var autoClose = new System.Windows.Forms.Timer { Interval = 20000 };
            autoClose.Tick += (_, _) => target.Close(); autoClose.Start(); Application.Run(target); return 0;
        }
        string directory = Path.Combine(Path.GetTempPath(), "nag-window-tests-" + Guid.NewGuid());
        string evidence = Path.GetFullPath(args.FirstOrDefault(a => !a.StartsWith("--")) ?? "build/windows-evidence");
        Directory.CreateDirectory(evidence);
        try
        {
            var store = new Store(directory);
            var state = new State
            {
                // Quiet mode suppresses the separate always-on-top panel in layout checks.
                Settings = new() { QuietEnabled = true, QuietStartHour = DateTime.Now.Hour, QuietEndHour = (DateTime.Now.Hour + 1) % 24 },
                Reminders = [new() { Title = "Take your vitamins", Notes = "A glass of water. One small step.", Due = DateTime.Now.AddMinutes(-20) },
                    new() { Title = "Send the project update", Notes = "Start with three bullet points.", Due = DateTime.Now.AddMinutes(-5) },
                    new() { Title = "Step outside for a walk", Due = DateTime.Now.AddHours(1), Repeat = Repeat.Daily }]
            };
            using var form = new MainWindow(store, state, true);
            form.Show(); Application.DoEvents();
            // DrawToBitmap checks actual WinForms layout without requiring screen capture permission.
            void Capture(string name, Size size)
            {
                form.Size = size; Application.DoEvents();
                using var bitmap = new Bitmap(form.Width, form.Height);
                form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
                bitmap.Save(Path.Combine(evidence, name + ".png"), ImageFormat.Png);
                Console.WriteLine($"Layout {name}: requested {size}; rendered {form.Size}");
                Check(Descendants(form).OfType<Button>().Any(b => b.Text == "Settings"), name + " navigation exists");
            }
            Capture("nags-runner", new(660, 500));
            Find(form, "Mark done").PerformClick(); Application.DoEvents();
            Check(store.Load().Reminders.Count(n => n.Finished) == 1, "UI completion persisted");
            Descendants(form).OfType<Button>().First(b => b.Text.StartsWith("Snooze 10m") && b.Enabled).PerformClick(); Application.DoEvents();
            Check(store.Load().Reminders.Count(n => n.Snoozed(DateTimeOffset.UtcNow)) == 1, "UI snooze persisted");
            Find(form, "Done").PerformClick(); Application.DoEvents();
            Check(Descendants(form).OfType<Button>().Any(b => b.Text == "Reopen"), "done filter exposes reopen");
            Find(form, "Reopen").PerformClick(); Application.DoEvents();
            Check(store.Load().Reminders.All(n => !n.Finished), "reopen persisted");
            Find(form, "Open").PerformClick(); Application.DoEvents();
            Exception? editorError = null;
            using (var fillEditor = new System.Windows.Forms.Timer { Interval = 150 })
            {
                fillEditor.Tick += (_, _) =>
                {
                    fillEditor.Stop();
                    var editor = Application.OpenForms.Cast<Form>().First(f => f.Text == "Add a nag");
                    try
                    {
                        Descendants(editor).OfType<TextBox>().First(t => t.AccessibleName == "What needs doing?").Text = "Created through the editor";
                        Find(editor, "Save").PerformClick();
                    }
                    catch (Exception ex) { editorError = ex; editor.Close(); }
                };
                fillEditor.Start(); Find(form, "+ Add a nag").PerformClick();
            }
            if (editorError is not null) throw editorError;
            Check(store.Load().Reminders.Any(n => n.Title == "Created through the editor"), "editor creates and persists a nag");
            Find(form, "Locks").PerformClick(); Capture("locks-narrow", new(660, 620));
            Find(form, "Settings").PerformClick(); Capture("settings-narrow", new(660, 620));
            if (args.Contains("--integration")) CheckAppMinimization(directory);
            Find(form, "Quit Nag").PerformClick(); Application.DoEvents();
            Console.WriteLine("Windows UI checks passed. Layout evidence: " + evidence);
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
    static void CheckAppMinimization(string directory)
    {
        string targetPath = Path.Combine(AppContext.BaseDirectory, "NagDisposableTarget.exe");
        File.Copy(Environment.ProcessPath!, targetPath, true);
        var start = new ProcessStartInfo(targetPath, "--lock-target") { UseShellExecute = false, RedirectStandardError = true };
        start.Environment["DOTNET_ROOT"] = Path.GetFullPath(Path.Combine(RuntimeEnvironment.GetRuntimeDirectory(), "../../.."));
        using var process = Process.Start(start)!;
        try
        {
            process.Refresh();
            var readyDeadline = DateTime.UtcNow.AddSeconds(5);
            while (process.MainWindowHandle == IntPtr.Zero && !process.HasExited && DateTime.UtcNow < readyDeadline)
            { Thread.Sleep(50); process.Refresh(); }
            if (process.HasExited) throw new Exception("Lock target exited: " + process.StandardError.ReadToEnd());
            var handle = process.MainWindowHandle;
            Check(handle != IntPtr.Zero, "disposable lock target opened");
            ShowWindow(handle, 9); SetForegroundWindow(handle);
            Check(GetForegroundWindow() == handle, "disposable target is foreground");
            var now = DateTimeOffset.Now;
            var state = new State
            {
                Settings = new() { QuietEnabled = true, QuietStartHour = now.Hour, QuietEndHour = (now.Hour + 1) % 24 },
                Reminders = [new() { Title = "Test lock", Due = now.LocalDateTime.AddMinutes(-1) }],
                Locks = [new() { Enabled = true, Executables = [targetPath] }]
            };
            using var form = new MainWindow(new Store(Path.Combine(directory, "lock-test")), state, true);
            var enforce = typeof(MainWindow).GetMethod("EnforceLocks", BindingFlags.Instance | BindingFlags.NonPublic)!;
            enforce.Invoke(form, [now]);
            var deadline = DateTime.UtcNow.AddSeconds(3);
            while (!IsIconic(handle) && DateTime.UtcNow < deadline) { Application.DoEvents(); Thread.Sleep(25); }
            Check(IsIconic(handle), "foreground executable is minimized without termination");
            Check(!process.HasExited, "locked app remains running");
        }
        finally
        {
            if (!process.HasExited) { process.CloseMainWindow(); if (!process.WaitForExit(3000)) { process.Kill(); process.WaitForExit(3000); } }
            try { File.Delete(targetPath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
}
