import NagKit
import SwiftUI

struct LockListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var editor: LockEditorItem?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    if model.screenTimeStatus != .approved {
                        Section {
                            ScreenTimeBanner()
                        }
                    }
                    ForEach(model.state.profiles) { profile in
                        LockRow(profile: profile, now: context.date) {
                            editor = .edit(profile)
                        }
                    }
                }
            }
            .navigationTitle("Locks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New lock", systemImage: "plus") { editor = .new }
                }
            }
            .overlay {
                if model.state.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No locks yet", systemImage: "lock.open")
                    } description: {
                        Text("Pick the apps that pull you away, and decide what it takes to open them.")
                    } actions: {
                        Button("New lock") { editor = .new }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .sheet(item: $editor) { item in
                LockEditorView(profile: item.profile)
            }
        }
    }
}

enum LockEditorItem: Identifiable {
    case new
    case edit(LockProfile)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let profile): profile.id.uuidString
        }
    }

    var profile: LockProfile? {
        if case .edit(let profile) = self { return profile }
        return nil
    }
}

private struct ScreenTimeBanner: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Time access needed", systemImage: "hourglass")
                .font(.headline)
            Text("Locks can't block apps until you allow it. Screen Time only works on a real iPhone, not the simulator.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Allow access") {
                Task { error = await model.requestScreenTime() }
            }
            .buttonStyle(.borderedProminent)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct LockRow: View {
    let profile: LockProfile
    let now: Date
    let onEdit: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: profile.symbol)
                    .font(.title2)
                    .foregroundStyle(profile.isShielding(at: now) ? .orange : .secondary)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.headline)
                    Text(profile.selectionSummary.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(profile: profile, now: now)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                switch profile.status {
                case .off:
                    Button("Lock now", systemImage: "lock.fill") { model.lockNow(profile.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(profile.selectionSummary.isEmpty)
                    Button("Edit", action: onEdit)
                        .buttonStyle(.bordered)
                case .locked:
                    Button("Unlock…", systemImage: "lock.open") { router.showUnlock(profile.id) }
                        .buttonStyle(.borderedProminent)
                case .unlocked:
                    Button("Lock again now", systemImage: "lock.fill") { model.relockNow(profile.id) }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private var detail: String {
        var parts: [String] = []
        if profile.requirements.isEmpty {
            parts.append("No unlock requirements: needs an emergency unlock")
        } else {
            parts.append(profile.requirements.map { UnlockEvaluator.title(for: $0.kind, state: model.state) }.joined(separator: " + "))
        }
        if let schedule = profile.schedule { parts.append(schedule.label) }
        if profile.lockWhileNagsDue { parts.append("Locks while nags are due") }
        return parts.joined(separator: "\n")
    }
}

struct StatusPill: View {
    let profile: LockProfile
    let now: Date

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var text: String {
        switch profile.status {
        case .off: "Off"
        case .locked: "Locked"
        case .unlocked(_, let until):
            until > now ? "Open until \(until.formatted(date: .omitted, time: .shortened))" : "Locking…"
        }
    }

    private var color: Color {
        switch profile.status {
        case .off: .secondary
        case .locked: .orange
        case .unlocked: .green
        }
    }
}
