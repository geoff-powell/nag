using System.Text.Json;
using System.Text.Json.Serialization;

namespace Nag.Core;

public enum Repeat { Once, Daily, Weekdays, Weekly }
public enum Escalation { Steady, Gentle, Relentless }

public sealed record Reminder
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string Notes { get; set; } = "";
    // Local wall clock: recurring reminders retain their local time across DST changes.
    public DateTime Due { get; set; } = DateTime.Now;
    public Repeat Repeat { get; set; }
    public int IntervalMinutes { get; set; } = 15;
    public Escalation Escalation { get; set; } = Escalation.Gentle;
    public int SnoozeMinutes { get; set; } = 10;
    public int MaxSnoozes { get; set; } = 3;
    public int SnoozeCount { get; set; }
    public DateTime? SnoozedUntil { get; set; }
    public DateTime? LastNotified { get; set; }
    public bool Finished { get; set; }

    public bool Outstanding(DateTime now) => !Finished && Due <= now;
    public bool Snoozed(DateTime now) => Outstanding(now) && SnoozedUntil > now;
    public string Status(DateTime now) => Finished ? "Done" : Snoozed(now) ? "Snoozed" : Outstanding(now) ? "Due" : "Upcoming";
    public double NotificationInterval(DateTime now)
    {
        double overdue = Math.Max(0, (now - Due).TotalMinutes);
        return Escalation switch
        {
            Escalation.Relentless => Math.Max(1, IntervalMinutes / Math.Pow(2, Math.Min(30, Math.Floor(overdue / 30)))),
            Escalation.Gentle => Math.Max(1, Math.Max(IntervalMinutes / 2d, IntervalMinutes * Math.Pow(.75, Math.Floor(overdue / 60)))),
            _ => IntervalMinutes
        };
    }
    public string Message(DateTime now) => (now - Due).TotalMinutes switch
    {
        >= 180 => "Still here. Take one small step, then mark it done.",
        >= 60 => "This is overdue. Two minutes is enough to start.",
        >= 15 => "Still waiting. Try the smallest next step.",
        _ => string.IsNullOrWhiteSpace(Notes) ? "It's time. Start with the smallest step." : Notes
    };
    public bool ShouldNotify(DateTime now, Settings settings) => Outstanding(now) && !Snoozed(now)
        && !settings.IsQuiet(now) && (LastNotified is null || (now - LastNotified.Value).TotalMinutes >= NotificationInterval(now));
    public void Snooze(DateTime now)
    {
        if (!Outstanding(now) || Snoozed(now) || SnoozeCount >= MaxSnoozes)
            throw new InvalidOperationException("This nag cannot be snoozed right now.");
        SnoozeCount++;
        SnoozedUntil = now.AddMinutes(SnoozeMinutes);
        LastNotified = null;
    }
    public void Complete(DateTime now)
    {
        if (Finished) return;
        if (Repeat == Repeat.Once) Finished = true;
        else
        {
            // Skip missed occurrences, retaining the scheduled hour and weekday.
            DateTime candidate = Due;
            if (candidate > now) throw new InvalidOperationException("This recurring nag is not due yet.");
            if (Repeat == Repeat.Weekly)
            {
                int weeks = (int)((now.Date - candidate.Date).TotalDays / 7);
                candidate = candidate.AddDays(Math.Max(0, weeks) * 7);
                while (candidate <= now) candidate = candidate.AddDays(7);
            }
            else
            {
                candidate = now.Date.Add(Due.TimeOfDay);
                while (candidate <= now || (Repeat == Repeat.Weekdays && candidate.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday))
                    candidate = candidate.AddDays(1);
            }
            Due = candidate;
        }
        SnoozeCount = 0;
        SnoozedUntil = null;
        LastNotified = null;
    }
    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(Title) || Title.Length > 200 || Notes.Length > 10000
            || IntervalMinutes is < 1 or > 1440 || SnoozeMinutes is < 1 or > 1440 || MaxSnoozes is < 0 or > 100
            || SnoozeCount < 0 || !Enum.IsDefined(Repeat) || !Enum.IsDefined(Escalation))
            throw new InvalidDataException("Invalid reminder settings.");
    }
}

public sealed record AppLock
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string Name { get; set; } = "Focus";
    public List<string> Executables { get; set; } = [];
    public bool Enabled { get; set; }
    public bool WhileDue { get; set; } = true;
    public DateTime? Until { get; set; }
    public DateTime? EmergencyUntil { get; set; }
    public bool Active(DateTime now, IEnumerable<Reminder> reminders) => Enabled && !(EmergencyUntil > now)
        && (WhileDue ? reminders.Any(n => n.Outstanding(now)) : Until > now);
}

public sealed record Settings
{
    public bool QuietEnabled { get; set; }
    public int QuietStartHour { get; set; } = 22;
    public int QuietEndHour { get; set; } = 8;
    public bool IsQuiet(DateTime now) => QuietEnabled && QuietStartHour != QuietEndHour
        && (QuietStartHour < QuietEndHour ? now.Hour >= QuietStartHour && now.Hour < QuietEndHour
            : now.Hour >= QuietStartHour || now.Hour < QuietEndHour);
}

public sealed record State
{
    public int Version { get; init; } = 1;
    public List<Reminder> Reminders { get; set; } = [];
    public List<AppLock> Locks { get; set; } = [];
    public Settings Settings { get; set; } = new();
    public void Validate()
    {
        if (Version != 1 || Reminders is null || Locks is null || Settings is null)
            throw new InvalidDataException("Unsupported or incomplete Windows store.");
        if (Settings.QuietStartHour is < 0 or > 23 || Settings.QuietEndHour is < 0 or > 23)
            throw new InvalidDataException("Invalid quiet hours.");
        foreach (var reminder in Reminders) reminder.Validate();
        if (Reminders.Select(n => n.Id).Distinct().Count() != Reminders.Count)
            throw new InvalidDataException("Duplicate reminder IDs.");
        foreach (var appLock in Locks)
            if (string.IsNullOrWhiteSpace(appLock.Name) || appLock.Executables is null
                || appLock.Executables.Any(p => !Path.IsPathFullyQualified(p) || !p.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)))
                throw new InvalidDataException("Invalid app lock.");
    }
}

public sealed class Store(string directory)
{
    public static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };
    public string FilePath => Path.Combine(directory, "windows-state.json");
    public State Load()
    {
        if (!File.Exists(FilePath)) return new();
        var state = JsonSerializer.Deserialize<State>(File.ReadAllText(FilePath), Json)
            ?? throw new InvalidDataException("The Windows store is empty.");
        state.Validate();
        return state;
    }
    public void Save(State state)
    {
        state.Validate();
        Directory.CreateDirectory(directory);
        string temporary = Path.Combine(directory, $".state-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                JsonSerializer.Serialize(file, state, Json);
                file.Flush(true);
            }
            if (File.Exists(FilePath)) File.Replace(temporary, FilePath, FilePath + ".bak");
            else File.Move(temporary, FilePath);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    // Publish in memory only after the durable write succeeds.
    public State Change(State current, Action<State> change)
    {
        var next = JsonSerializer.Deserialize<State>(JsonSerializer.Serialize(current, Json), Json)!;
        change(next);
        Save(next);
        return next;
    }
}
