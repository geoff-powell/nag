using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Nag.Conformance;

// Minimal .NET consumer of the KMP prototype: runs the shared fixtures through nag_eval, then probes
// the bridge's error handling, threading and memory ownership. Exit code 1 on any failure.
NativeLibrary.SetDllImportResolver(Assembly.GetExecutingAssembly(), NagRules.Resolve);
Console.WriteLine($"Runtime: {RuntimeInformation.FrameworkDescription} on {RuntimeInformation.RuntimeIdentifier}");

var failures = new List<string>();
void Check(string name, Func<bool> test)
{
    bool ok;
    try { ok = test(); } catch (Exception error) { ok = false; Console.WriteLine($"  {error}"); }
    Console.WriteLine($"{(ok ? "PASS" : "FAIL")} {name}");
    if (!ok) failures.Add(name);
}

const string probe = """{"op":"escalation","mode":"gentle","baseSeconds":960,"overdueSeconds":0}""";
var timer = Stopwatch.StartNew();
_ = NagRules.Eval(probe);
Console.WriteLine($"Native library: {NagRules.LibraryPath} ({new FileInfo(NagRules.LibraryPath).Length / 1024} KiB)");
Console.WriteLine($"First call, including library load and JIT: {timer.Elapsed.TotalMilliseconds:F1} ms");
timer.Restart();
_ = NagRules.Eval(probe);
Console.WriteLine($"Second call: {timer.Elapsed.TotalMilliseconds:F3} ms");

Check("shared conformance fixtures", () =>
{
    var result = ConformanceRunner.Run(new KmpEvaluator());
    foreach (string note in result.Notes) Console.WriteLine("  " + note);
    foreach (string failure in result.Failures) Console.WriteLine("  " + failure);
    Console.WriteLine($"  {result.Passed} cases matched, {result.Skipped} skipped");
    return result.Failures.Count == 0 && result.Passed > 0;
});

Check("invalid JSON is reported, not thrown", () =>
    JsonNode.Parse(NagRules.Eval("not json"))!["ok"]!.GetValue<bool>() == false);

Check("unknown op is reported", () =>
    ((string)JsonNode.Parse(NagRules.Eval("""{"op":"nope"}"""))!["error"]!).Contains("Unknown op"));

Check("NULL request is reported", () =>
{
    IntPtr response = NagRules.nag_eval(IntPtr.Zero);
    try { return Marshal.PtrToStringUTF8(response)!.Contains("\"ok\":false"); }
    finally { NagRules.nag_free(response); }
});

Check("non-ASCII input survives the UTF-8 boundary", () =>
    ((string)JsonNode.Parse(NagRules.Eval("""{"op":"escalation","mode":"gentlé"}"""))!["error"]!).Contains("gentlé"));

Check("concurrent calls from 8 threads agree", () =>
{
    var results = new System.Collections.Concurrent.ConcurrentBag<string>();
    Parallel.For(0, 8_000, new ParallelOptions { MaxDegreeOfParallelism = 8 }, _ => results.Add(NagRules.Eval(
        """{"op":"escalation","mode":"relentless","baseSeconds":960,"overdueSeconds":5400}""")));
    return results.Count == 8_000 && results.Distinct().Count() == 1;
});

Check("repeated calls do not leak (100k eval/free pairs)", () =>
{
    const string request = """{"op":"snooze","now":1793178000000,"task":{"startAt":1793174400000,"completed":false,"snoozeMinutes":10,"maxSnoozes":3,"snoozeCount":0,"snoozedUntil":null}}""";
    for (int i = 0; i < 10_000; i++) NagRules.Eval(request);
    GC.Collect();
    long before = Process.GetCurrentProcess().WorkingSet64;
    var sw = Stopwatch.StartNew();
    for (int i = 0; i < 100_000; i++) NagRules.Eval(request);
    sw.Stop();
    GC.Collect();
    long growth = Process.GetCurrentProcess().WorkingSet64 - before;
    Console.WriteLine($"  {sw.Elapsed.TotalMicroseconds / 100_000:F1} µs per call; working set change {growth / 1024} KiB");
    return growth < 64 * 1024 * 1024;
});

Console.WriteLine(failures.Count == 0 ? "All checks passed." : $"{failures.Count} check(s) failed.");
return failures.Count == 0 ? 0 : 1;

static partial class NagRules
{
    public static string LibraryPath { get; private set; } = "";

    [LibraryImport("nagrules")]
    internal static partial IntPtr nag_eval(IntPtr request);

    [LibraryImport("nagrules")]
    internal static partial void nag_free(IntPtr response);

    /// Sends a request and copies the response into managed memory before releasing the native copy.
    public static string Eval(string request)
    {
        IntPtr input = Marshal.StringToCoTaskMemUTF8(request);
        try
        {
            IntPtr response = nag_eval(input);
            try { return Marshal.PtrToStringUTF8(response) ?? throw new InvalidOperationException("nag_eval returned NULL"); }
            finally { nag_free(response); }
        }
        finally { Marshal.FreeCoTaskMem(input); }
    }

    /// NAGRULES_LIB, or the Gradle release output for this OS.
    public static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? path)
    {
        if (name != "nagrules") return IntPtr.Zero;
        string? configured = Environment.GetEnvironmentVariable("NAGRULES_LIB");
        if (string.IsNullOrEmpty(configured))
        {
            string root = ConformanceRunner.FindFixtures();
            string build = Path.GetFullPath(Path.Combine(root, "../../kmp/nag-rules/build/bin"));
            configured = OperatingSystem.IsWindows()
                ? Path.Combine(build, "mingwX64/releaseShared/nagrules.dll")
                : Path.Combine(build, "macosArm64/releaseShared/libnagrules.dylib");
        }
        LibraryPath = configured;
        return NativeLibrary.Load(configured);
    }
}

sealed class KmpEvaluator : IRulesEvaluator
{
    public string Platform => "kotlin";
    public IReadOnlySet<string> UnsupportedFields { get; } = new HashSet<string>();

    public JsonObject Evaluate(JsonObject input)
    {
        var response = JsonNode.Parse(NagRules.Eval(input.ToJsonString()))!.AsObject();
        if (!response["ok"]!.GetValue<bool>()) throw new InvalidOperationException((string)response["error"]!);
        return response["result"]!.AsObject();
    }
}
