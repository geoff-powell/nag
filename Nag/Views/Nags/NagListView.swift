import NagKit
import SwiftUI

struct NagListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var editor: TaskEditorItem?
    @State private var feedbackTick = 0

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
                            Button("Clear") { withAnimation(Motion.list) { model.clearFinished() } }
                                .font(.caption)
                                .transition(.opacity)
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
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        // Also animates changes that don't come from a tap here: a nag coming due, or Done and
        // Snooze from a notification or another device.
        .animation(Motion.list, value: groups.signature)
        .sensoryFeedback(.selection, trigger: feedbackTick)
    }

    private func row(_ task: NagTask, now: Date) -> some View {
        NagRow(task: task, now: now, needsScan: model.proofKey(for: task) != nil) {
            complete(task)
        }
        .contentShape(Rectangle())
        .onTapGesture { editor = .edit(task) }
        .swipeActions(edge: .leading) {
            if task.canComplete(at: now, calendar: model.calendar) {
                Button { complete(task, fromSwipe: true) } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            if task.canSnooze(at: now) {
                Button { snooze(task) } label: {
                    Label("Snooze", systemImage: "zzz")
                }
                .tint(.indigo)
            }
            if task.isFinished {
                Button { reopen(task) } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward")
                }
            }
        }
        .listRowBackground(router.focusedTask == task.id ? Color.orange.opacity(0.15) : nil)
        .contextMenu {
            Button("Duplicate", systemImage: "plus.square.on.square") {
                withAnimation(Motion.list) { model.duplicateTask(task.id) }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                withAnimation(Motion.list) { model.deleteTask(task.id) }
            }
            .disabled(!model.canDeleteTask(task.id))
        }
    }

    /// The check button fills in place before calling this. From the swipe action, the haptic fires
    /// here and the row waits for the swipe to close before moving to Done.
    private func complete(_ task: NagTask, fromSwipe: Bool = false) {
        if model.proofKey(for: task) != nil {
            router.showProof(for: task.id)
            return
        }
        guard fromSwipe else {
            withAnimation(Motion.list) { model.complete(task.id) }
            return
        }
        feedbackTick += 1
        afterSwipeCloses { withAnimation(Motion.list) { model.complete(task.id) } }
    }

    private func snooze(_ task: NagTask) {
        feedbackTick += 1
        withAnimation(Motion.list) { model.snooze(task.id) }
    }

    private func reopen(_ task: NagTask) {
        feedbackTick += 1
        afterSwipeCloses { withAnimation(Motion.list) { model.reopen(task.id) } }
    }

    private func afterSwipeCloses(_ change: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: Motion.swipeSettle)
            change()
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
        signature = [now, later, done].map { section in
            section.map { "\($0.id)|\($0.isSnoozed(at: date))|\($0.isFinished)" }
        }
    }

    /// Which nag is in which section, in order, and whether each is snoozed or finished. Changes
    /// exactly when the list's layout does, not when a relative time like "Overdue 21m" ticks over.
    private(set) var signature: [[String]] = []
}
