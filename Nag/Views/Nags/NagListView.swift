import NagKit
import SwiftUI

struct NagListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var editor: TaskEditorItem?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                list(now: context.date)
            }
            .navigationTitle("Nags")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New nag", systemImage: "plus") { editor = .new }
                }
            }
            .sheet(item: $editor) { item in
                TaskEditorView(task: item.task)
            }
        }
    }

    private func list(now: Date) -> some View {
        let groups = NagGroups(tasks: model.state.tasks, now: now, calendar: model.calendar)
        return List {
            if !groups.now.isEmpty {
                Section("Now") {
                    ForEach(groups.now) { row($0, now: now) }
                }
            }
            if !groups.later.isEmpty {
                Section("Coming up") {
                    ForEach(groups.later) { row($0, now: now) }
                }
            }
            if !groups.done.isEmpty {
                Section {
                    ForEach(groups.done) { row($0, now: now) }
                } header: {
                    HStack {
                        Text("Done")
                        Spacer()
                        if groups.done.contains(where: \.isFinished) {
                            Button("Clear") { withAnimation { model.clearFinished() } }
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.state.tasks.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to nag about", systemImage: "checkmark.seal")
                } description: {
                    Text("Add the things you keep forgetting. Nag will keep at you until they're done.")
                } actions: {
                    Button("New nag") { editor = .new }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func row(_ task: NagTask, now: Date) -> some View {
        NagRow(task: task, now: now, needsScan: model.proofKey(for: task) != nil) {
            complete(task)
        }
        .contentShape(Rectangle())
        .onTapGesture { editor = .edit(task) }
        .swipeActions(edge: .leading) {
            if task.canComplete(at: now, calendar: model.calendar) {
                Button { complete(task) } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            if task.canSnooze(at: now) {
                Button { model.snooze(task.id) } label: {
                    Label("Snooze", systemImage: "zzz")
                }
                .tint(.indigo)
            }
            if task.isFinished {
                Button { model.reopen(task.id) } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .listRowBackground(router.focusedTask == task.id ? Color.orange.opacity(0.15) : nil)
    }

    private func complete(_ task: NagTask) {
        if model.proofKey(for: task) != nil {
            router.showProof(for: task.id)
        } else {
            withAnimation { model.complete(task.id) }
        }
    }
}

enum TaskEditorItem: Identifiable {
    case new
    case edit(NagTask)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let task): task.id.uuidString
        }
    }

    var task: NagTask? {
        switch self {
        case .new: nil
        case .edit(let task): task
        }
    }
}

/// Splits nags into what's due now, what's coming, and what's been done today.
struct NagGroups {
    var now: [NagTask] = []
    var later: [NagTask] = []
    var done: [NagTask] = []

    init(tasks: [NagTask], now date: Date, calendar: Calendar) {
        for task in tasks {
            if task.isOutstanding(at: date) {
                now.append(task)
            } else if task.isFinished || task.lastCompletedAt.map({ calendar.isDate($0, inSameDayAs: date) }) == true {
                done.append(task)
            } else {
                later.append(task)
            }
        }
        now.sort { $0.startAt < $1.startAt }
        later.sort { $0.startAt < $1.startAt }
        done.sort { ($0.lastCompletedAt ?? .distantPast) > ($1.lastCompletedAt ?? .distantPast) }
    }
}
