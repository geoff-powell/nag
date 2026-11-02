using Nag.Core;
using System.Security.Cryptography;
using System.Text;

namespace Nag.Windows;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        string directory = Environment.GetEnvironmentVariable("NAG_WINDOWS_HOME")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Nag");
        directory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory));
        var store = new Store(directory);
        string identity = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(store.FilePath).ToUpperInvariant())));
        using var mutex = new Mutex(true, @"Local\Nag.Windows." + identity, out bool created);
        if (!created)
        {
            MessageBox.Show("Nag is already running. Open it from the notification area.", "Nag");
            return;
        }
        try
        {
            bool demo = args.Contains("--demo");
            if (demo)
            {
                if (Environment.GetEnvironmentVariable("NAG_WINDOWS_HOME") is null)
                    throw new InvalidOperationException("Demo mode requires an isolated NAG_WINDOWS_HOME.");
                if (File.Exists(store.FilePath))
                    throw new InvalidOperationException("Demo mode requires an empty NAG_WINDOWS_HOME; an existing store was found.");
            }
            var state = demo ? new State
            {
                Reminders = [new() { Title = "Take your vitamins", Notes = "A glass of water. One small step.", Due = DateTime.Now.AddMinutes(-20) },
                    new() { Title = "Step outside for a walk", Due = DateTime.Now.AddHours(1), Repeat = Repeat.Daily },
                    new() { Title = "Send the project update", Notes = "Start with three bullet points.", Due = DateTime.Now.AddMinutes(-5) }]
            } : store.Load();
            using var window = new MainWindow(store, state, demo);
            if (args.Contains("--background")) window.StartInTray = true;
            Application.Run(window);
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Nag could not open its store. No existing data was replaced.\n\n{ex.Message}", "Nag", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
