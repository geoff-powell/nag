using Nag.Core;

namespace Nag.Windows;

internal abstract class EditorWindow : Form
{
    protected readonly TableLayoutPanel Fields = new() { Dock = DockStyle.Fill, ColumnCount = 2, AutoScroll = true, Padding = new(24) };
    protected EditorWindow(string title)
    {
        Text = title; Size = new(560, 700); MinimumSize = new(460, 520); StartPosition = FormStartPosition.CenterParent;
        Font = new("Segoe UI", 10); BackColor = MainWindow.Paper; MinimizeBox = false; MaximizeBox = false;
        Fields.ColumnStyles.Add(new(SizeType.Absolute, 150)); Fields.ColumnStyles.Add(new(SizeType.Percent, 100));
        Controls.Add(Fields);
    }
    protected void Field(string caption, Control control)
    {
        int row = Fields.RowCount++;
        Fields.RowStyles.Add(new(SizeType.AutoSize));
        var label = MainWindow.Label(caption); label.Margin = new(0, 10, 10, 12);
        control.Dock = DockStyle.Fill; control.Margin = new(0, 6, 0, 12); control.AccessibleName = caption;
        Fields.Controls.Add(label, 0, row); Fields.Controls.Add(control, 1, row);
    }
    protected void Buttons(Action save)
    {
        var buttons = new FlowLayoutPanel { AutoSize = true };
        var submit = MainWindow.Button("Save", save, true); var cancel = MainWindow.Button("Cancel", () => { DialogResult = DialogResult.Cancel; Close(); });
        buttons.Controls.Add(submit); buttons.Controls.Add(cancel); Field("", buttons); AcceptButton = submit; CancelButton = cancel;
    }
    protected static ComboBox Options<T>(T selected) where T : struct, Enum
    {
        var box = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, DataSource = Enum.GetValues<T>() }; box.SelectedItem = selected; return box;
    }
    protected static NumericUpDown Number(int value, int min, int max) => new() { Minimum = min, Maximum = max, Value = Math.Clamp(value, min, max) };
}

internal sealed class ReminderEditor : EditorWindow
{
    public Reminder? Result { get; private set; }
    public ReminderEditor(Reminder? original) : base(original is null ? "Add a nag" : "Edit nag")
    {
        var reminder = original ?? new();
        var title = new TextBox { Text = reminder.Title, MaxLength = 200 };
        var notes = new TextBox { Text = reminder.Notes, Multiline = true, Height = 85, MaxLength = 10000, ScrollBars = ScrollBars.Vertical, AcceptsReturn = true };
        var due = new DateTimePicker { Format = DateTimePickerFormat.Custom, CustomFormat = "MMM dd, yyyy  HH:mm", Value = reminder.Due };
        var repeat = Options(reminder.Repeat); var escalation = Options(reminder.Escalation);
        var interval = Number(reminder.IntervalMinutes, 1, 1440); var snooze = Number(reminder.SnoozeMinutes, 1, 1440); var limit = Number(reminder.MaxSnoozes, 0, 100);
        Field("What needs doing?", title); Field("First small step", notes); Field("Starts (local time)", due); Field("Repeat", repeat);
        Field("Nag every (minutes)", interval); Field("Escalation", escalation); Field("Snooze (minutes)", snooze); Field("Snoozes allowed", limit);
        Buttons(() =>
        {
            if (string.IsNullOrWhiteSpace(title.Text)) { MessageBox.Show(this, "Give your nag a title.", "Nag"); title.Focus(); return; }
            var updated = reminder with { Title = title.Text.Trim(), Notes = notes.Text, Due = due.Value, Repeat = (Repeat)repeat.SelectedItem!,
                IntervalMinutes = (int)interval.Value, Escalation = (Escalation)escalation.SelectedItem!, SnoozeMinutes = (int)snooze.Value, MaxSnoozes = (int)limit.Value };
            if (updated.Due != reminder.Due || updated.Repeat != reminder.Repeat)
            { updated.SnoozeCount = 0; updated.SnoozedUntil = null; updated.LastNotified = null; updated.Finished = false; }
            updated.Validate(); Result = updated; DialogResult = DialogResult.OK; Close();
        });
    }
}

internal sealed class LockEditor : EditorWindow
{
    public AppLock? Result { get; private set; }
    public LockEditor() : base("Create app lock")
    {
        var name = new TextBox { Text = "Focus", MaxLength = 100 };
        var mode = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList };
        mode.Items.AddRange(["While any nag is due", "For a timer"]); mode.SelectedIndex = 0;
        var minutes = Number(30, 1, 1440);
        var apps = new ListBox { Height = 150, HorizontalScrollbar = true };
        var paths = new List<string>();
        Field("Name", name); Field("Lock condition", mode); Field("Timer (minutes)", minutes); Field("Selected executables", apps);
        Field("", MainWindow.Button("Choose .exe…", () =>
        {
            using var dialog = new OpenFileDialog { Filter = "Windows applications (*.exe)|*.exe", Multiselect = true, CheckFileExists = true };
            if (dialog.ShowDialog(this) != DialogResult.OK) return;
            foreach (string path in dialog.FileNames)
            {
                if (MainWindow.ProtectedApp(path)) { MessageBox.Show(this, "Nag and Windows system apps cannot be locked.", "Nag"); continue; }
                if (!paths.Contains(path, StringComparer.OrdinalIgnoreCase)) { paths.Add(path); apps.Items.Add(path); }
            }
        }));
        Field("", MainWindow.Button("Remove selected", () => { int i = apps.SelectedIndex; if (i >= 0) { paths.RemoveAt(i); apps.Items.RemoveAt(i); } }));
        Field("How it works", new System.Windows.Forms.Label { Text = "Apps are minimized, never closed. Locks apply only while Nag is running. Emergency unlock is always available.", AutoSize = true, MaximumSize = new(280, 0) });
        Buttons(() =>
        {
            if (string.IsNullOrWhiteSpace(name.Text) || paths.Count == 0) { MessageBox.Show(this, "Name your lock and choose at least one app.", "Nag"); return; }
            Result = new() { Name = name.Text.Trim(), Executables = paths, Enabled = true, WhileDue = mode.SelectedIndex == 0,
                Until = mode.SelectedIndex == 1 ? DateTime.Now.AddMinutes((int)minutes.Value) : null };
            DialogResult = DialogResult.OK; Close();
        });
    }
}
