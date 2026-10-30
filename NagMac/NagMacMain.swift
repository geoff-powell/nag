import AppKit
import NagCore
import NagMCP

/// Nag's entry point. Launched with `--mcp`, it's an MCP server on stdin and stdout for AI assistants
/// on this Mac, instead of the menu bar app.
@main
enum NagMacMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains(MCPCommand.flag) {
            MCPCommand.run()
        } else {
            NagMacApp.main()
        }
    }
}

/// `Nag --mcp`: the stdio MCP server that Claude Desktop, Claude Code, Cursor and the like launch.
///
/// It works on the same store as the menu bar app, which notices each change, re-plans notifications and
/// syncs to iCloud. Nag has to be running for nags to nag, so the first change launches it if needed.
enum MCPCommand {
    static let flag = "--mcp"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    @MainActor
    static func run() -> Never {
        let tools = NagTools(store: .shared, onChange: {
            Task { @MainActor in launchAppIfNeeded() }
        })
        let server = MCPServer(tools: tools, version: version)
        Task.detached {
            await MCPStdio.run(server: server)
            exit(0)
        }
        dispatchMain()
    }

    /// Opens the menu bar app in the background unless it's already running.
    @MainActor
    static func launchAppIfNeeded() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me }
        guard !running else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { MCPStdio.log("Couldn't open Nag: \(error.localizedDescription)") }
        }
    }
}
