import NagKit
import SwiftUI

struct MacNagsView: View {
    @Environment(MacModel.self) private var model
    @State private var editing: MacTaskEditorItem?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let groups = MacNagGroups(tasks: model.state.tasks, now: context.date, calendar: model.calendar)
            List {
                section("Now", groups.now, now: context.date)
                section("Coming up", groups.later, now: context.date)
                section("Done", groups.done, now: context.date)
            }
            .overlay {
                if model.state.tasks.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to nag about", systemImage: "checkmark.seal")
                    } description: {
                        Text("Add the things you keep forgetting. Nag keeps at you until they're done, here and on your iPhone.")
                    } actions: {
                        Button("New nag") { editing = .new }
                    }
                }
            }
        }
        .navigationTitle("Nags")
        .toolbar {
            ToolbarItem {
                Button("Clear done", systemImage: "checkmark.circle.badge.xmark") { model.clearFinished() }
                    .disabled(!model.state.tasks.contains(where: \.isFinished))
            }
            ToolbarItem {
                Button("New nag", systemImage: "plus") { editing = .new }
                    .keyboardShortcut("n")
            }
        }
        .sheet(item: $editing) { item in
            MacTaskEditor(task: item.task)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ tasks: [NagTask], now: Date) -> some View {
        if !tasks.isEmpty {
            Section(title) {
                ForEach(tasks) { task in
                    MacNagRow(task: task, now: now) { editing = .edit(task) }
                }
            }
        }
    }
}

enum MacTaskEditorItem: Identifiable {
    case new
    case edit(NagTask)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let task): task.id.uuidString
        }
    }

    var task: NagTask? {
        if case .edit(let task) = self { return task }
        return nil
    }
}

private struct MacNagRow: View {
    let task: NagTask
    let now: Date
    let onEdit: () -> Void
    @Environment(MacModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if task.isFinished { model.reopen(task.id) } else { model.complete(task.id) }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? Color.green : task.isOutstanding(at: now) ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!task.isFinished && (model.needsPhoneScan(task) || !task.canComplete(at: now, calendar: model.calendar)))

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .fontWeight(task.isOutstanding(at: now) ? .semibold : .regular)
                    .strikethrough(task.isFinished)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(task.isOutstanding(at: now) && !task.isSnoozed(at: now) ? Color.orange : Color.secondary)
            }
            Spacer()
            if model.needsPhoneScan(task) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                    .help("Needs a key scan on iPhone to finish")
            }
            if task.isRepeating {
                Image(systemName: "repeat").foregroundStyle(.secondary).help(task.repeatLabel)
            }
            if task.canSnooze(at: now) {
                Button("Snooze") { model.snooze(task.id) }.controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Duplicate") { model.duplicateTask(task.id) }
            if task.canSnooze(at: now) { Button("Snooze") { model.snooze(task.id) } }
            Divider()
            Button("Delete", role: .destructive) { model.deleteTask(task.id) }
                .disabled(!model.canDeleteTask(task.id))
        }
    }

    private var done: Bool {
        task.isFinished || task.isSatisfied(at: now, calendar: model.calendar)
    }

    private var status: String {
        if task.isFinished, let at = task.completedAt { return "Done \(at.formatted(.relative(presentation: .named)))" }
        if task.isSnoozed(at: now), let until = task.snoozedUntil {
            return "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if task.isOutstanding(at: now) {
            let overdue = now.timeIntervalSince(task.startAt)
            let left = task.snoozesLeft.map { " · \($0) snooze\($0 == 1 ? "" : "s") left" } ?? ""
            return (overdue < 60 ? "Due now" : "Overdue \(NagFormat.duration(overdue))") + left
        }
        if done { return "Done today · next \(task.startAt.formatted(.relative(presentation: .named)))" }
        return "Starts \(task.startAt.formatted(.relative(presentation: .named)))"
    }
}

struct MacTaskEditor: View {
    @Environment(MacModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let isNew: Bool
    private let original: NagTask?
    @State private var task: NagTask
    @State private var startNow: Bool
    @State private var limitSnoozes: Bool

    init(task: NagTask?) {
        isNew = task == nil
        original = task
        let initial = task ?? NagTask(title: "")
        _task = State(initialValue: initial)
        _startNow = State(initialValue: task == nil)
        _limitSnoozes = State(initialValue: initial.style.maxSnoozes != nil)
    }

    private var isCustom: Bool { task.repeatRule == .custom }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("What needs doing?", text: $task.title)
                    TextField("Notes, or the first tiny step", text: $task.notes, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section("When") {
                    if !isCustom {
                        if isNew { Toggle("Start nagging now", isOn: $startNow) }
                        if !startNow || !isNew {
                            DatePicker("Starts", selection: $task.startAt)
                        }
                    }
                    Picker("Repeat", selection: $task.repeatRule) {
                        ForEach(RepeatRule.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                if isCustom {
                    timesSection
                }
                Section {
                    Picker("Nag every", selection: $task.style.intervalMinutes) {
                        ForEach([1, 2, 5, 10, 15, 30, 60], id: \.self) { Text(NagFormat.minutes($0)).tag($0) }
                    }
                    Picker("Escalation", selection: $task.style.escalation) {
                        ForEach(Escalation.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Break through Focus", isOn: $task.style.breakThroughFocus)
                } header: {
                    Text("Nagging")
                } footer: {
                    Text(task.style.escalation.explanation).foregroundStyle(.secondary)
                }
                Section("Snooze") {
                    Picker("Snooze for", selection: $task.style.snoozeMinutes) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { Text(NagFormat.minutes($0)).tag($0) }
                    }
                    Toggle("Limit snoozes", isOn: $limitSnoozes)
                    if limitSnoozes {
                        Stepper(
                            "\(task.style.maxSnoozes ?? 3) per occurrence",
                            value: Binding(get: { task.style.maxSnoozes ?? 3 }, set: { task.style.maxSnoozes = $0 }),
                            in: 0...10
                        )
                    }
                }
                if model.needsPhoneScan(task) {
                    Section {
                        Label("Finishing this needs a key scan on your iPhone.", systemImage: "iphone.radiowaves.left.and.right")
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.deleteTask(task.id)
                        dismiss()
                    }
                    .disabled(!model.canDeleteTask(task.id))
                    .help(model.canDeleteTask(task.id) ? "" : "An active lock needs this nag done.")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if isNew && startNow && !isCustom { task.startAt = .now }
                    task.alignStartToSchedule(previous: original, now: .now, calendar: model.calendar)
                    if !limitSnoozes { task.style.maxSnoozes = nil }
                    model.saveTask(task)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty || !task.hasValidSchedule)
            }
            .padding()
        }
        .frame(width: 560, height: 600)
        .onChange(of: task.repeatRule) { _, rule in
            if rule == .custom, task.times.isEmpty {
                task.times = [NagTime(minute: minuteOfDay(task.startAt))]
            }
        }
    }

    private var timesSection: some View {
        Section {
            ForEach($task.times) { $time in
                HStack {
                    DatePicker("Time", selection: minuteBinding($time.minute), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer()
                    ForEach(1...7, id: \.self) { day in
                        Toggle(model.calendar.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                            get: { time.weekdays.contains(day) },
                            set: { on in
                                if on { time.weekdays.insert(day) } else { time.weekdays.remove(day) }
                            }
                        ))
                        .toggleStyle(.button)
                        .help(model.calendar.weekdaySymbols[day - 1])
                    }
                    Button("Remove time", systemImage: "minus.circle") {
                        task.times.removeAll { $0.id == time.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            Button("Add time", systemImage: "plus") {
                task.times.append(NagTime(minute: task.times.last.map { ($0.minute + 60) % 1440 } ?? 9 * 60))
            }
            if !task.hasValidSchedule {
                Text("Add at least one time, and pick at least one day for each.").foregroundStyle(.red)
            }
        } header: {
            Text("Times")
        }
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let parts = model.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
    }

    private func minuteBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                model.calendar.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60, second: 0, of: .now) ?? .now
            },
            set: { minute.wrappedValue = minuteOfDay($0) }
        )
    }
}
