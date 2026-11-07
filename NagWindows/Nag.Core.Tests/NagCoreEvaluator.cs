using System.Text.Json.Nodes;
using Nag.Conformance;
using Nag.Core;

/// Maps the shared fixtures onto Nag.Core. Snoozing either succeeds or throws, so canSnooze is
/// whether Reminder.Snooze succeeded. Nag.Core has no next-tightening rule.
sealed class NagCoreEvaluator : IRulesEvaluator
{
    public string Platform => "csharp";
    public IReadOnlySet<string> UnsupportedFields { get; } = new HashSet<string> { "nextTighteningSeconds" };

    public JsonObject Evaluate(JsonObject input) => (string)input["op"]! switch
    {
        "escalation" => Escalate(input),
        "snooze" or "complete" => Act(input),
        var op => throw new NotSupportedException($"Unknown op {op}")
    };

    static JsonObject Escalate(JsonObject input)
    {
        double baseSeconds = (double)input["baseSeconds"]!;
        if (baseSeconds % 60 != 0) throw new ArgumentException("Nag.Core intervals are whole minutes");
        var now = new DateTime(2026, 10, 28, 9, 0, 0, DateTimeKind.Utc);
        var reminder = new Reminder
        {
            Title = "Fixture",
            Due = now.AddSeconds(-(double)input["overdueSeconds"]!),
            IntervalMinutes = (int)(baseSeconds / 60),
            Escalation = Enum.Parse<Escalation>((string)input["mode"]!, ignoreCase: true),
        };
        reminder.Validate();
        return new JsonObject { ["intervalSeconds"] = reminder.NotificationInterval(now) * 60 };
    }

    static JsonObject Act(JsonObject input)
    {
        var now = ConformanceRunner.Date((long)input["now"]!);
        var task = input["task"]!.AsObject();
        var reminder = new Reminder
        {
            Title = "Fixture",
            Due = ConformanceRunner.Date((long)task["startAt"]!),
            Finished = (bool)task["completed"]!,
            SnoozeMinutes = (int)task["snoozeMinutes"]!,
            MaxSnoozes = (int?)task["maxSnoozes"] ?? throw new ArgumentException("Nag.Core cannot represent unlimited snoozes"),
            SnoozeCount = (int)task["snoozeCount"]!,
            SnoozedUntil = task["snoozedUntil"] is JsonNode until ? ConformanceRunner.Date((long)until) : null,
        };
        reminder.Validate();
        var result = new JsonObject();
        if ((string)input["op"]! == "snooze")
        {
            bool snoozed;
            try { reminder.Snooze(now); snoozed = true; }
            catch (InvalidOperationException) { snoozed = false; }
            result["canSnooze"] = snoozed;
        }
        else reminder.Complete(now);
        result["task"] = new JsonObject
        {
            ["startAt"] = ConformanceRunner.Millis(reminder.Due),
            ["completed"] = reminder.Finished,
            ["snoozeMinutes"] = reminder.SnoozeMinutes,
            ["maxSnoozes"] = reminder.MaxSnoozes,
            ["snoozeCount"] = reminder.SnoozeCount,
            ["snoozedUntil"] = reminder.SnoozedUntil is DateTime value ? ConformanceRunner.Millis(value) : null,
        };
        return result;
    }
}
