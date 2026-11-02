using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Nag.Core;

namespace Nag.Windows;

public sealed class MainWindow : Form
{
    internal static readonly Color Ink = Color.FromArgb(39, 42, 38);
    internal static readonly Color Accent = Color.FromArgb(190, 78, 33);
    internal static readonly Color Paper = Color.FromArgb(249, 248, 244);
    private readonly Store store;
    private State state;
    private readonly bool demo;
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 2000 };
    private readonly FlowLayoutPanel body = new() { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new(28, 12, 24, 24) };
    private readonly Label subtitle = new() { AutoSize = true, ForeColor = Color.DimGray };
    private readonly Label feedback = new() { Dock = DockStyle.Bottom, Height = 34, Padding = new(20, 6, 0, 0), ForeColor = Accent };
    private readonly Dictionary<string, Button> navigation = [];
    private string page = "Nags", filter = "Open", signature = "";
    private bool exiting;
    private ReminderPanel? nagPanel;
    private DateTime lastBlockNotice;
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    internal bool StartInTray { get; set; }

    public MainWindow(Store store, State state, bool demo)
    {
        this.store = store; this.state = state; this.demo = demo;
        Text = demo ? "Nag · Demo" : "Nag";
        Size = new(1080, 760); MinimumSize = new(640, 520);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Paper; ForeColor = Ink; Font = new("Segoe UI", 10);
        Icon = SystemIcons.Information;
        var sidebar = new Panel { Dock = DockStyle.Left, Width = 174, BackColor = Color.FromArgb(239, 238, 231), Padding = new(18, 28, 18, 16) };
        var brand = Label("nag", 32, true); brand.Location = new(20, 24); sidebar.Controls.Add(brand);
        var tagline = Label("A little persistence.", 9); tagline.Location = new(22, 87); sidebar.Controls.Add(tagline);
        int y = 145;
        foreach (string name in new[] { "Nags", "Locks", "Settings" })
        {
            var button = Button(name, () => { page = name; Render(); });
            button.SetBounds(16, y, 142, 44); sidebar.Controls.Add(button); navigation[name] = button; y += 54;
        }
        var local = new System.Windows.Forms.Label { Text = "WINDOWS\nStored on this device", Dock = DockStyle.Bottom, Height = 55, ForeColor = Color.DimGray, Font = new("Segoe UI", 9) };
        sidebar.Controls.Add(local);
        var content = new Panel { Dock = DockStyle.Fill };
        var heading = new Panel { Dock = DockStyle.Top, Height = 130, Padding = new(28, 26, 28, 10) };
        var title = Label("One small step.", 23, true); title.Location = new(28, 25);
        subtitle.Location = new(30, 81); heading.Controls.Add(title); heading.Controls.Add(subtitle);
        content.Controls.Add(body); content.Controls.Add(heading); content.Controls.Add(feedback);
        Controls.Add(content); Controls.Add(sidebar);
        body.SizeChanged += (_, _) => LayoutBody();
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open Nag", null, (_, _) => Open());
        menu.Items.Add("Add a nag", null, (_, _) => { Open(); Edit(null); });
        menu.Items.Add("Quit Nag", null, (_, _) => Quit());
        tray = new NotifyIcon { Icon = Icon, Text = "Nag · A little persistence", Visible = true, ContextMenuStrip = menu };
        tray.DoubleClick += (_, _) => Open(); tray.BalloonTipClicked += (_, _) => Open();
        FormClosing += (_, e) =>
        {
            if (!exiting && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true; Hide();
                tray.ShowBalloonTip(3000, "Nag is still here", "Reminders and locks continue in the notification area. Use Quit Nag to exit.", ToolTipIcon.Info);
            }
        };
        Shown += (_, _) => { if (StartInTray) Hide(); };
        timer.Tick += (_, _) => Tick(); timer.Start(); Render();
    }

    internal static System.Windows.Forms.Label Label(string text, float size = 10, bool bold = false) => new()
    { Text = text, AutoSize = true, Font = new("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular), ForeColor = Ink };
    internal static Button Button(string text, Action click, bool primary = false)
    {
        var button = new Button { Text = text, AutoSize = true, MinimumSize = new(90, 36), Padding = new(10, 4, 10, 4),
            FlatStyle = FlatStyle.Flat, BackColor = primary ? Accent : Color.White, ForeColor = primary ? Color.White : Ink,
            Cursor = Cursors.Hand, Margin = new(0, 0, 8, 8) };
        button.FlatAppearance.BorderColor = primary ? Accent : Color.FromArgb(213, 213, 203);
        button.Click += (_, _) => click(); return button;
    }
    private void Open() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    private bool Change(Action<State> change)
    {
        try { state = store.Change(state, change); feedback.Text = "Saved on this device."; Render(); return true; }
        catch (Exception ex) { MessageBox.Show(this, "The change was not saved.\n\n" + ex.Message, "Nag", MessageBoxButtons.OK, MessageBoxIcon.Error); return false; }
    }
    private void Render()
    {
        body.SuspendLayout();
        foreach (Control control in body.Controls.Cast<Control>().ToArray()) control.Dispose();
        body.Controls.Clear();
        foreach (var (name, button) in navigation) button.BackColor = page == name ? Color.FromArgb(225, 219, 203) : Color.Transparent;
        int due = state.Reminders.Count(n => n.Outstanding(DateTime.Now));
        subtitle.Text = $"{due} waiting for you · Small steps count. " + (demo ? "Demo · App enforcement disabled" : "");
        if (page == "Nags") RenderNags(); else if (page == "Locks") RenderLocks(); else RenderSettings();
        LayoutBody();
        body.ResumeLayout();
        signature = StateSignature();
        UpdatePanel();
    }
    private void LayoutBody()
    {
        int width = Math.Max(260, body.ClientSize.Width - 64);
        subtitle.MaximumSize = new(Math.Max(200, width + 8), 0);
        foreach (Control control in body.Controls)
        {
            control.MaximumSize = new(width, 0);
            control.Width = width;
            if (control is FlowLayoutPanel panel)
            {
                int inner = Math.Max(200, width - panel.Padding.Horizontal - 4);
                foreach (Control child in panel.Controls)
                    if (child is System.Windows.Forms.Label or FlowLayoutPanel)
                        child.MaximumSize = new(inner, 0);
            }
        }
    }
    private FlowLayoutPanel Row() => new() { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = true, Margin = new(0, 0, 0, 10) };
    private void RenderNags()
    {
        var actions = Row(); actions.Controls.Add(Button("+ Add a nag", () => Edit(null), true));
        foreach (string name in new[] { "Open", "Due", "Done", "All" })
        {
            var b = Button(name, () => { filter = name; Render(); });
            if (filter == name) b.BackColor = Color.FromArgb(239, 230, 208);
            actions.Controls.Add(b);
        }
        body.Controls.Add(actions);
        var now = DateTime.Now;
        var reminders = state.Reminders.Where(n => filter switch { "Open" => !n.Finished, "Due" => n.Outstanding(now), "Done" => n.Finished, _ => true })
            .OrderBy(n => n.Finished).ThenBy(n => n.Due).ToList();
        if (reminders.Count == 0) AddText("A little breathing room.", "Add something you want to follow through on. Nag will keep it in sight until it's done.");
        foreach (var reminder in reminders)
        {
            var card = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false,
                BackColor = Color.White, Padding = new(18), Margin = new(0, 0, 0, 12), BorderStyle = BorderStyle.FixedSingle };
            var status = Label($"{reminder.Status(now).ToUpperInvariant()}  ·  {reminder.Due:g}  ·  {reminder.Repeat}", 9);
            status.ForeColor = reminder.Outstanding(now) ? Accent : Color.DimGray; card.Controls.Add(status);
            var title = Label(reminder.Title, 16, true); title.MaximumSize = new(460, 0); title.Margin = new(0, 8, 0, 8); card.Controls.Add(title);
            if (reminder.Notes.Length > 0)
            {
                var notes = Label(reminder.Notes); notes.MaximumSize = new(460, 0); notes.Margin = new(0, 0, 0, 10); card.Controls.Add(notes);
            }
            if (reminder.Snoozed(now)) card.Controls.Add(Label($"Quiet until {reminder.SnoozedUntil:t}", 9));
            var controls = Row();
            if (!reminder.Finished)
            {
                var done = Button("Mark done", () => Complete(reminder.Id), true);
                done.Enabled = reminder.Repeat == Repeat.Once || reminder.Outstanding(now); controls.Controls.Add(done);
                var snooze = Button($"Snooze {reminder.SnoozeMinutes}m ({Math.Max(0, reminder.MaxSnoozes - reminder.SnoozeCount)} left)", () => Snooze(reminder.Id));
                snooze.Enabled = reminder.Outstanding(now) && !reminder.Snoozed(now) && reminder.SnoozeCount < reminder.MaxSnoozes;
                controls.Controls.Add(snooze);
            }
            else controls.Controls.Add(Button("Reopen", () => Change(s => { var n = s.Reminders.Single(n => n.Id == reminder.Id); n.Finished = false; n.Due = DateTime.Now; })));
            controls.Controls.Add(Button("Edit", () => Edit(reminder)));
            controls.Controls.Add(Button("Delete", () =>
            {
                if (MessageBox.Show(this, $"Delete “{reminder.Title}”?", "Nag", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes)
                    Change(s => s.Reminders.RemoveAll(n => n.Id == reminder.Id));
            }));
            card.Controls.Add(controls); body.Controls.Add(card);
        }
    }
    private void AddText(string title, string description)
    {
        body.Controls.Add(Label(title, 18, true));
        var label = Label(description); label.MaximumSize = new(500, 0); label.Margin = new(0, 10, 0, 24); body.Controls.Add(label);
    }
    private void Edit(Reminder? reminder)
    {
        using var editor = new ReminderEditor(reminder);
        if (editor.ShowDialog(this) != DialogResult.OK) return;
        Change(s =>
        {
            var updated = editor.Result!;
            int index = s.Reminders.FindIndex(n => n.Id == updated.Id);
            if (index < 0) s.Reminders.Add(updated); else s.Reminders[index] = updated;
        });
    }
    internal void Complete(Guid id) => Change(s => s.Reminders.Single(n => n.Id == id).Complete(DateTime.Now));
    internal void Snooze(Guid id) => Change(s => s.Reminders.Single(n => n.Id == id).Snooze(DateTime.Now));

    private void RenderLocks()
    {
        AddText("Protect your attention.", "Selected apps are minimized when you open them during a lock. Snoozing a nag keeps its lock active. Nag must remain running.");
        body.Controls.Add(Button("+ Create app lock", () =>
        {
            using var editor = new LockEditor();
            if (editor.ShowDialog(this) == DialogResult.OK) Change(s => s.Locks.Add(editor.Result!));
        }, true));
        foreach (var appLock in state.Locks)
        {
            var row = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new(16), BackColor = Color.White, Margin = new(0, 10, 0, 10) };
            row.Controls.Add(Label(appLock.Name, 16, true));
            row.Controls.Add(Label(appLock.Active(DateTime.Now, state.Reminders) ? "ACTIVE" : appLock.Enabled ? "Waiting / temporarily unlocked" : "Off", 9));
            foreach (string exe in appLock.Executables) row.Controls.Add(Label(Path.GetFileName(exe), 9));
            row.Controls.Add(Label(appLock.WhileDue ? "Until all due nags are done" : $"Timer ends {appLock.Until:g}", 9));
            var actions = Row();
            actions.Controls.Add(Button(appLock.Enabled ? "Turn off" : "Turn on", () => Change(s =>
            {
                var item = s.Locks.Single(l => l.Id == appLock.Id);
                if (!item.Enabled && !item.WhileDue && item.Until <= DateTime.Now)
                    throw new InvalidOperationException("This timer has ended. Create a new timed lock.");
                item.Enabled = !item.Enabled;
            })));
            actions.Controls.Add(Button("Emergency unlock · 5m", () => Change(s => s.Locks.Single(l => l.Id == appLock.Id).EmergencyUntil = DateTime.Now.AddMinutes(5))));
            actions.Controls.Add(Button("Delete", () => Change(s => s.Locks.RemoveAll(l => l.Id == appLock.Id))));
            row.Controls.Add(actions); body.Controls.Add(row);
        }
    }
    private void RenderSettings()
    {
        AddText("Keep Nag close.", "Closing the window keeps reminders running in the notification area. Quitting Nag stops reminders and app locks. Notifications may be silenced by Windows Do not disturb.");
        var quiet = new CheckBox { Text = "Quiet hours", Checked = state.Settings.QuietEnabled, AutoSize = true };
        var start = new NumericUpDown { Minimum = 0, Maximum = 23, Value = state.Settings.QuietStartHour, Width = 80, AccessibleName = "Quiet hours start" };
        var end = new NumericUpDown { Minimum = 0, Maximum = 23, Value = state.Settings.QuietEndHour, Width = 80, AccessibleName = "Quiet hours end" };
        body.Controls.Add(quiet); var row = Row(); row.Controls.Add(Label("From hour (24h)")); row.Controls.Add(start); row.Controls.Add(Label("to")); row.Controls.Add(end); body.Controls.Add(row);
        body.Controls.Add(Button("Save quiet hours", () => Change(s => { s.Settings.QuietEnabled = quiet.Checked; s.Settings.QuietStartHour = (int)start.Value; s.Settings.QuietEndHour = (int)end.Value; })));
        body.Controls.Add(Button("Enable open at login", () => SetLogin(true)));
        body.Controls.Add(Button("Disable open at login", () => SetLogin(false)));
        AddText("Your data stays here.", store.FilePath + "\nWindows storage is independent of the Apple apps. iCloud, NFC, Screen Time and step-count unlocks are not available in this version.");
        body.Controls.Add(Button("Quit Nag", Quit));
    }
    private void SetLogin(bool enabled)
    {
        if (demo || Environment.GetEnvironmentVariable("NAG_WINDOWS_HOME") is not null)
        { feedback.Text = "Login changes are disabled when using an isolated store."; return; }
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
            if (enabled) key.SetValue("Nag.Windows", $"\"{Environment.ProcessPath}\" --background");
            else key.DeleteValue("Nag.Windows", false);
            feedback.Text = enabled ? "Nag will open at your next Windows login." : "Open at login disabled.";
        }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "Could not change open at login"); }
    }
    private string StateSignature() => string.Join('|', state.Reminders.Select(n => n.Id + n.Status(DateTime.Now)))
        + string.Join('|', state.Locks.Select(l => l.Active(DateTime.Now, state.Reminders)));
    private void Tick()
    {
        var now = DateTime.Now;
        var due = state.Reminders.Where(n => n.ShouldNotify(now, state.Settings)).ToList();
        if (due.Count > 0)
        {
            // One grouped notification per tick avoids flooding the Windows notification queue.
            if (Change(s => { foreach (var n in s.Reminders.Where(n => due.Any(d => d.Id == n.Id))) n.LastNotified = now; }))
                tray.ShowBalloonTip(5000, due.Count == 1 ? due[0].Title : $"{due.Count} nags need a small step",
                    due.Count == 1 ? due[0].Message(now)[..Math.Min(220, due[0].Message(now).Length)] : "Still here. Mark it done when it is.", ToolTipIcon.Info);
        }
        if (signature != StateSignature()) Render(); else UpdatePanel();
        if (!demo) EnforceLocks(now);
    }
    private void UpdatePanel()
    {
        var due = state.Reminders.Where(n => n.Outstanding(DateTime.Now) && !n.Snoozed(DateTime.Now)).ToList();
        if (due.Count == 0 || state.Settings.IsQuiet(DateTime.Now)) { nagPanel?.Hide(); return; }
        if (nagPanel is null || nagPanel.IsDisposed) nagPanel = new ReminderPanel(this);
        nagPanel.UpdateReminders(due);
        if (!nagPanel.Visible) nagPanel.Show();
    }
    private void EnforceLocks(DateTime now)
    {
        var active = state.Locks.Where(l => l.Active(now, state.Reminders)).ToList();
        if (active.Count == 0) return;
        IntPtr window = GetForegroundWindow();
        if (window == IntPtr.Zero) return;
        GetWindowThreadProcessId(window, out uint pid);
        if (pid == Environment.ProcessId) return;
        try
        {
            using var process = Process.GetProcessById((int)pid);
            string? path = process.MainModule?.FileName;
            if (path is null || ProtectedApp(path)) return;
            if (!active.Any(l => l.Executables.Contains(path, StringComparer.OrdinalIgnoreCase))) return;
            ShowWindowAsync(window, 6); // SW_MINIMIZE: never terminate another process or discard its work.
            if ((now - lastBlockNotice).TotalSeconds > 10)
            {
                lastBlockNotice = now;
                tray.ShowBalloonTip(3000, "A little space to focus", "This app is locked. Complete your due nags or use Emergency unlock in Nag → Locks.", ToolTipIcon.Info);
            }
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or ArgumentException or NotSupportedException)
        { feedback.Text = "Windows could not inspect this app; its lock could not be enforced."; }
    }
    internal static bool ProtectedApp(string path) => string.Equals(path, Environment.ProcessPath, StringComparison.OrdinalIgnoreCase)
        || path.StartsWith(Environment.GetFolderPath(Environment.SpecialFolder.Windows) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    private void Quit()
    {
        if (!demo && state.Locks.Any(l => l.Active(DateTime.Now, state.Reminders))
            && MessageBox.Show(this, "Quitting stops active app locks and reminders. Quit anyway?", "Nag", MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        exiting = true; nagPanel?.Dispose(); tray.Visible = false; Close();
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { timer.Stop(); timer.Dispose(); tray.Dispose(); nagPanel?.Dispose(); }
        base.Dispose(disposing);
    }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
}

internal sealed class ReminderPanel : Form
{
    private readonly MainWindow owner;
    private string signature = "";
    private readonly FlowLayoutPanel contents = new() { Dock = DockStyle.Fill, Padding = new(16), FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true };
    protected override bool ShowWithoutActivation => true;
    public ReminderPanel(MainWindow owner)
    {
        this.owner = owner; Text = "Nag · Still here"; Size = new(330, 280); MinimumSize = new(300, 220);
        FormBorderStyle = FormBorderStyle.SizableToolWindow; ShowInTaskbar = false; TopMost = true;
        BackColor = MainWindow.Paper; Font = new("Segoe UI", 10); Controls.Add(contents);
        StartPosition = FormStartPosition.Manual;
        var area = Screen.PrimaryScreen!.WorkingArea; Location = new(area.Right - Width - 18, area.Bottom - Height - 18);
        FormClosing += (_, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
    }
    public void UpdateReminders(List<Reminder> reminders)
    {
        string next = string.Join('|', reminders.Select(n => n.Id + n.Title + n.SnoozeCount));
        if (signature == next) return; signature = next;
        foreach (Control c in contents.Controls.Cast<Control>().ToArray()) c.Dispose(); contents.Controls.Clear();
        contents.Controls.Add(MainWindow.Label($"{reminders.Count} waiting for you", 11, true));
        foreach (var n in reminders)
        {
            var label = MainWindow.Label(n.Title, 12, true); label.MaximumSize = new(260, 0); label.Margin = new(0, 14, 0, 6); contents.Controls.Add(label);
            var row = new FlowLayoutPanel { AutoSize = true, MaximumSize = new(270, 0) };
            row.Controls.Add(MainWindow.Button("Done", () => owner.Complete(n.Id), true));
            var snooze = MainWindow.Button($"Snooze {n.SnoozeMinutes}m", () => owner.Snooze(n.Id)); snooze.Enabled = n.SnoozeCount < n.MaxSnoozes;
            row.Controls.Add(snooze); contents.Controls.Add(row);
        }
    }
}
