using System.Text.Json;
using System.Text.Json.Nodes;

namespace Nag.Conformance;

/// Evaluates one fixture input (the case's "input" object) and returns an object shaped like its
/// "expect". Throw to report a failure.
public interface IRulesEvaluator
{
    /// The key used for "overrides" and "skip" in the fixture files.
    string Platform { get; }
    /// Expected fields this implementation has no equivalent for; they are reported, not compared.
    IReadOnlySet<string> UnsupportedFields { get; }
    JsonObject Evaluate(JsonObject input);
}

public sealed record ConformanceResult(int Passed, int Skipped, IReadOnlyList<string> Failures, IReadOnlyList<string> Notes);

/// Runs the language-neutral fixtures in Fixtures/conformance (#41). Shared by Nag.Core.Tests and
/// the KMP prototype's .NET consumer.
public static class ConformanceRunner
{
    public static readonly string[] Files = ["escalation", "snooze"];

    public static string FindFixtures()
    {
        foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
            for (var dir = new DirectoryInfo(start); dir is not null; dir = dir.Parent)
            {
                string candidate = Path.Combine(dir.FullName, "Fixtures", "conformance");
                if (Directory.Exists(candidate)) return candidate;
            }
        throw new DirectoryNotFoundException("Fixtures/conformance not found above the working directory.");
    }

    public static ConformanceResult Run(IRulesEvaluator evaluator, string? directory = null)
    {
        directory ??= FindFixtures();
        int passed = 0, skipped = 0;
        var failures = new List<string>();
        var notes = new List<string>();
        foreach (string file in Files)
        {
            var root = JsonNode.Parse(File.ReadAllText(Path.Combine(directory, file + ".json")))!.AsObject();
            if ((int)root["schema"]! != 1) throw new InvalidDataException($"{file}: unsupported schema");
            foreach (var node in root["cases"]!.AsArray())
            {
                var fixture = node!.AsObject();
                string name = $"{file}: {(string)fixture["name"]!}";
                if (fixture["skip"]?[evaluator.Platform] is JsonNode reason)
                {
                    skipped++;
                    notes.Add($"SKIP {name} ({(string)reason!})");
                    continue;
                }
                var expected = fixture["expect"]!.AsObject();
                if (fixture["overrides"]?[evaluator.Platform] is JsonObject over)
                {
                    expected = over["expect"]!.AsObject();
                    notes.Add($"DIFF {name} ({(string)over["reason"]!})");
                }
                try
                {
                    var actual = evaluator.Evaluate(fixture["input"]!.DeepClone().AsObject());
                    var problems = new List<string>();
                    Compare("", expected, actual, evaluator.UnsupportedFields, problems);
                    if (problems.Count == 0) passed++;
                    else failures.Add($"{name}: {string.Join("; ", problems)}");
                }
                catch (Exception error)
                {
                    failures.Add($"{name}: {error.GetType().Name}: {error.Message}");
                }
            }
        }
        foreach (string field in evaluator.UnsupportedFields) notes.Add($"NOT COMPARED {field}");
        return new(passed, skipped, failures, notes);
    }

    static void Compare(string path, JsonNode? expected, JsonNode? actual, IReadOnlySet<string> unsupported, List<string> problems)
    {
        if (expected is JsonObject expectedObject)
        {
            if (actual is not JsonObject actualObject) { problems.Add($"{path}: expected an object, got {Show(actual)}"); return; }
            foreach (var (key, value) in expectedObject)
            {
                string child = path.Length == 0 ? key : $"{path}.{key}";
                if (unsupported.Contains(key)) continue;
                if (!actualObject.ContainsKey(key)) { problems.Add($"{child}: missing"); continue; }
                Compare(child, value, actualObject[key], unsupported, problems);
            }
            return;
        }
        if (expected is null || actual is null)
        {
            if (expected is not null || actual is not null) problems.Add($"{path}: expected {Show(expected)}, got {Show(actual)}");
            return;
        }
        var kind = expected.GetValueKind();
        if (kind == JsonValueKind.Number && actual.GetValueKind() == JsonValueKind.Number)
        {
            double e = Number(expected), a = Number(actual);
            if (Math.Abs(e - a) > 1e-9) problems.Add($"{path}: expected {e}, got {a}");
            return;
        }
        if (!JsonNode.DeepEquals(expected, actual)) problems.Add($"{path}: expected {Show(expected)}, got {Show(actual)}");
    }

    static string Show(JsonNode? node) => node?.ToJsonString() ?? "null";

    // Values built in code keep their CLR type (long, int, double), so read them back through JSON text.
    static double Number(JsonNode node) => double.Parse(node.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture);

    public static long Millis(DateTime value) => (long)Math.Round((value - DateTime.UnixEpoch).TotalMilliseconds);
    public static DateTime Date(long millis) => DateTime.UnixEpoch.AddMilliseconds(millis);
}
