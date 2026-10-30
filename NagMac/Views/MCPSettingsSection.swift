import AppKit
import SwiftUI

/// Settings for AI assistants: how to connect local MCP clients, and the optional HTTP server.
struct MCPSettingsSection: View {
    @Environment(MCPController.self) private var mcp
    @State private var showsToken = false
    @State private var copied: String?

    var body: some View {
        Section {
            LabeledContent("Apps on this Mac") {
                HStack {
                    copyButton("Copy JSON config", mcp.stdioConfig, help: "For Claude Desktop, Cursor and other apps' MCP settings")
                    copyButton("Copy Claude Code command", mcp.claudeCodeStdioCommand)
                }
            }

            Toggle("Serve over HTTP", isOn: Binding(get: { mcp.isEnabled }, set: { mcp.setEnabled($0) }))

            if mcp.isEnabled {
                Toggle("Allow other devices on the network", isOn: Binding(
                    get: { mcp.allowsNetwork },
                    set: { mcp.setAllowsNetwork($0) }
                ))
                TextField("Port", value: Binding(get: { mcp.port }, set: { mcp.setPort($0) }), format: .number.grouping(.never))
                LabeledContent("Status") {
                    Text(statusText).foregroundStyle(statusColor)
                }
                LabeledContent("URL") {
                    HStack {
                        Text(mcp.endpoint).textSelection(.enabled).monospaced()
                        copyButton("Copy", mcp.endpoint)
                    }
                }
                LabeledContent("Token") {
                    HStack {
                        Text(showsToken ? mcp.token : String(repeating: "•", count: 12))
                            .textSelection(.enabled)
                            .monospaced()
                        Button(showsToken ? "Hide" : "Show") { showsToken.toggle() }
                        copyButton("Copy", mcp.token)
                        Button("New token") { mcp.regenerateToken() }
                            .help("Clients using the current token stop working")
                    }
                }
                LabeledContent("Claude Code") {
                    copyButton("Copy command", mcp.claudeCodeHTTPCommand)
                }
            }
        } header: {
            Text("AI assistants (MCP)")
        } footer: {
            Text(footer).foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        var text = """
            Claude, Cursor and other MCP clients can add, list, finish and snooze nags. Apps on this Mac \
            start Nag themselves, so they don't need the HTTP server. Over HTTP every request needs the token, \
            sent as “Authorization: Bearer <token>”.
            """
        if mcp.isEnabled && mcp.allowsNetwork {
            text += " The connection isn't encrypted, so only allow other devices on networks you trust, or reach Nag through an HTTPS tunnel."
        }
        return text
    }

    private var statusText: String {
        switch mcp.status {
        case .off: "Off"
        case .starting: "Starting…"
        case .running(let port): "Running on port \(port)"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch mcp.status {
        case .running: .green
        case .failed: .red
        default: .secondary
        }
    }

    private func copyButton(_ title: String, _ value: String, help: String? = nil) -> some View {
        Button(copied == value ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = value
        }
        .help(help ?? "")
    }
}
