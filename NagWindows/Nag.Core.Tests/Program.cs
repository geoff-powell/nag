using Nag.Core;

int passed = 0;
void Check(string name, Action test)
{
    test(); passed++; Console.WriteLine("PASS " + name);
}
void Equal<T>(T expected, T actual)
{
    if (!Equals(expected, actual)) throw new Exception($"Expected {expected}; got {actual}");
}
var friday = new DateTime(2026, 10, 30, 9, 0, 0);
Check("daily completion skips missed occurrences and retains wall clock", () =>
{
    var n = new Reminder { Due = friday, Repeat = Repeat.Daily };
    n.Complete(friday.AddDays(5).AddHours(1)); Equal(friday.AddDays(6), n.Due); Equal(false, n.Finished);
});
Check("weekdays skips weekend", () =>
{
    var n = new Reminder { Due = friday, Repeat = Repeat.Weekdays }; n.Complete(friday.AddMinutes(1)); Equal(friday.AddDays(3), n.Due);
});
Check("weekly preserves weekday after a long absence", () =>
{
    var n = new Reminder { Due = friday, Repeat = Repeat.Weekly }; n.Complete(friday.AddDays(16)); Equal(friday.AddDays(21), n.Due);
});
Check("snooze is outstanding, silent, and limited", () =>
{
    var n = new Reminder { Due = friday, MaxSnoozes = 1 }; n.Snooze(friday);
    Equal(true, n.Outstanding(friday)); Equal(false, n.ShouldNotify(friday, new()));
    Equal(true, n.ShouldNotify(friday.AddMinutes(10), new()));
    try { n.Snooze(friday.AddMinutes(11)); throw new Exception("Limit ignored"); } catch (InvalidOperationException) { }
});
Check("completion resets per-occurrence state", () =>
{
    var n = new Reminder { Due = friday, Repeat = Repeat.Daily }; n.Snooze(friday); n.Complete(friday);
    Equal(0, n.SnoozeCount); Equal<DateTimeOffset?>(null, n.SnoozedUntil); Equal<DateTimeOffset?>(null, n.LastNotified);
});
Check("quiet hours span midnight and exclude ending hour", () =>
{
    var settings = new Settings { QuietEnabled = true }; Equal(true, settings.IsQuiet(friday.Date.AddHours(23)));
    Equal(true, settings.IsQuiet(friday.Date.AddHours(7))); Equal(false, settings.IsQuiet(friday.Date.AddHours(8)));
    settings.QuietStartHour = 8; settings.QuietEndHour = 17; Equal(true, settings.IsQuiet(friday));
    settings.QuietEndHour = 8; Equal(false, settings.IsQuiet(friday));
});
Check("gentle escalation matches NagCore's hourly factor and one-minute floor", () =>
{
    var n = new Reminder { Due = friday, IntervalMinutes = 16, Escalation = Escalation.Gentle };
    Equal(12d, n.NotificationInterval(friday.AddHours(1))); Equal(9d, n.NotificationInterval(friday.AddHours(2)));
    n.IntervalMinutes = 1; Equal(1d, n.NotificationInterval(friday.AddDays(10)));
});
Check("reminder wording escalates with overdue time", () =>
{
    var n = new Reminder { Due = friday, Notes = "Drink some water." };
    Equal("Drink some water.", n.Message(friday));
    Equal(true, n.Message(friday.AddHours(1)).Contains("overdue"));
});
Check("escalation bounds and notification cadence", () =>
{
    var n = new Reminder { Due = friday, Escalation = Escalation.Relentless, LastNotified = friday };
    Equal(false, n.ShouldNotify(friday.AddSeconds(1), new())); Equal(true, n.ShouldNotify(friday.AddMinutes(15), new()));
    Equal(1d, n.NotificationInterval(friday.AddDays(50))); n.Escalation = Escalation.Gentle; Equal(7.5, n.NotificationInterval(friday.AddDays(50)));
});
Check("one-off completion and notification suppression", () =>
{
    var n = new Reminder { Due = friday }; n.Complete(friday); Equal(true, n.Finished); Equal(false, n.ShouldNotify(friday.AddDays(1), new()));
});
Check("due locks survive snooze; emergency unlock expires", () =>
{
    var n = new Reminder { Due = friday }; var l = new AppLock { Enabled = true }; n.Snooze(friday);
    Equal(true, l.Active(friday, [n])); l.EmergencyUntil = friday.AddMinutes(5); Equal(false, l.Active(friday, [n]));
    Equal(true, l.Active(friday.AddMinutes(5), [n])); n.Complete(friday); Equal(false, l.Active(friday, [n]));
});
Check("timed locks stop at deadline", () =>
{
    var l = new AppLock { Enabled = true, WhileDue = false, Until = friday.AddMinutes(30) };
    Equal(true, l.Active(friday, [])); Equal(false, l.Active(friday.AddMinutes(30), []));
});
// Explicit offsets (US Eastern) keep these independent of the machine's time zone.
var longAgo = new DateTime(2000, 1, 1);
var beforeFallBack = new DateTimeOffset(2026, 11, 1, 1, 58, 0, TimeSpan.FromHours(-4));
// 15 minutes later, though the wall clock reads 45 minutes earlier.
var afterFallBack = new DateTimeOffset(2026, 11, 1, 1, 13, 0, TimeSpan.FromHours(-5));
Check("emergency unlock lasts five minutes across a fall-back change", () =>
{
    var n = new Reminder { Due = longAgo }; var l = new AppLock { Enabled = true, EmergencyUntil = beforeFallBack.AddMinutes(5) };
    Equal(false, l.Active(beforeFallBack.AddMinutes(4), [n])); Equal(true, l.Active(afterFallBack, [n]));
});
Check("notification cadence continues across a fall-back change", () =>
{
    var n = new Reminder { Due = longAgo, Escalation = Escalation.Steady, LastNotified = beforeFallBack };
    Equal(false, n.ShouldNotify(beforeFallBack.AddMinutes(14), new())); Equal(true, n.ShouldNotify(afterFallBack, new()));
});
Check("snooze is not cut short by a spring-forward change", () =>
{
    var beforeSpringForward = new DateTimeOffset(2026, 3, 8, 1, 55, 0, TimeSpan.FromHours(-5));
    var afterSpringForward = new DateTimeOffset(2026, 3, 8, 3, 0, 0, TimeSpan.FromHours(-4)); // 5 minutes later
    var n = new Reminder { Due = longAgo, SnoozeMinutes = 10 }; n.Snooze(beforeSpringForward);
    Equal(true, n.Snoozed(afterSpringForward)); Equal(false, n.Snoozed(beforeSpringForward.AddMinutes(10)));
});
string directory = Path.Combine(Path.GetTempPath(), "nag-tests-" + Guid.NewGuid());
try
{
    var store = new Store(directory);
    Check("atomic store round-trip and backup", () =>
    {
        var state = new State { Reminders = [new() { Title = "Test", Due = friday }] }; store.Save(state);
        var next = store.Change(state, s => s.Reminders[0].Title = "Updated");
        Equal("Updated", store.Load().Reminders[0].Title); Equal("Test", state.Reminders[0].Title); Equal(true, File.Exists(store.FilePath + ".bak"));
    });
    Check("invalid mutations leave durable and in-memory state unchanged", () =>
    {
        var state = store.Load();
        try { store.Change(state, s => s.Reminders[0].IntervalMinutes = 0); throw new Exception("Invalid save accepted"); } catch (InvalidDataException) { }
        Equal(15, state.Reminders[0].IntervalMinutes); Equal(15, store.Load().Reminders[0].IntervalMinutes);
    });
    Check("corrupt state fails closed without replacement", () =>
    {
        File.WriteAllText(store.FilePath, "broken");
        try { store.Load(); throw new Exception("Corruption ignored"); } catch (System.Text.Json.JsonException) { }
        Equal("broken", File.ReadAllText(store.FilePath));
    });
    Check("incomplete store is rejected rather than treated as empty", () =>
    {
        File.WriteAllText(store.FilePath, "{}");
        try { store.Load(); throw new Exception("Incomplete store accepted"); } catch (System.Text.Json.JsonException) { }
    });
    Check("store missing a nested required key is rejected", () =>
    {
        var state = new State { Reminders = [new() { Title = "Test", Due = friday }] }; store.Save(state);
        string json = File.ReadAllText(store.FilePath);
        string withoutId = System.Text.RegularExpressions.Regex.Replace(json, "\"Id\": \"[^\"]+\",\\s*\"Title\"", "\"Title\"");
        if (withoutId == json) throw new Exception("Test setup failed to remove Id");
        File.WriteAllText(store.FilePath, withoutId);
        try { store.Load(); throw new Exception("Reminder without Id accepted"); } catch (System.Text.Json.JsonException) { }
        File.WriteAllText(store.FilePath, json.Replace("\"Settings\"", "\"Setting\""));
        try { store.Load(); throw new Exception("Store without Settings accepted"); } catch (System.Text.Json.JsonException) { }
    });
    Check("fully serialized state with null optional timestamps still loads", () =>
    {
        var state = new State { Reminders = [new() { Title = "Test", Due = friday }], Locks = [new() { Name = "Focus" }] }; store.Save(state);
        var loaded = store.Load();
        Equal<DateTimeOffset?>(null, loaded.Reminders[0].SnoozedUntil); Equal<DateTimeOffset?>(null, loaded.Reminders[0].LastNotified);
        Equal<DateTimeOffset?>(null, loaded.Locks[0].Until);
    });
    Check("stores written with local offsets load as the same instants", () =>
    {
        var state = new State { Reminders = [new() { Title = "Test", Due = friday }], Locks = [new() { Name = "Focus" }] }; store.Save(state);
        string json = File.ReadAllText(store.FilePath);
        string legacy = json.Replace("\"SnoozedUntil\": null", "\"SnoozedUntil\": \"2026-10-30T09:10:00.1234567+01:00\"")
            .Replace("\"Until\": null", "\"Until\": \"2026-10-30T09:30:00-04:00\"");
        if (legacy == json) throw new Exception("Test setup failed to write legacy timestamps");
        File.WriteAllText(store.FilePath, legacy);
        var loaded = store.Load();
        Equal<DateTimeOffset?>(new DateTimeOffset(2026, 10, 30, 8, 10, 0, TimeSpan.Zero).AddTicks(1234567), loaded.Reminders[0].SnoozedUntil);
        Equal<DateTimeOffset?>(new DateTimeOffset(2026, 10, 30, 13, 30, 0, TimeSpan.Zero), loaded.Locks[0].Until);
    });
    Check("incomplete store does not overwrite the last backup", () =>
    {
        var state = new State { Reminders = [new() { Title = "Good", Due = friday }] };
        store.Save(state); store.Save(state);
        string backup = File.ReadAllText(store.FilePath + ".bak");
        File.WriteAllText(store.FilePath, "{}");
        try { store.Load(); throw new Exception("Incomplete store accepted"); } catch (System.Text.Json.JsonException) { }
        Equal(backup, File.ReadAllText(store.FilePath + ".bak"));
    });
}
finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
Console.WriteLine($"{passed} checks passed.");
