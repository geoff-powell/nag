import NagKit
import SwiftUI

struct MacNagsView: View {
    @Environment(MacModel.self) private var model
    @State private var editing: MacTaskEditorItem?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            // The tick's date can be up to 30s old when a change re-renders the list.
            let now = max(context.date, .now)
            let groups = MacNagGroups(tasks: model.state.tasks, now: now, calendar: model.calendar)
            List {
                section("Now", groups.now, now: now)
                section("Coming up", groups.later, now: now)
                section("Done", groups.done, now: now)
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
                    .transition(.opacity)
                }
            }
            // Rows slide between sections however they change: here, the menu bar, a notification or the iPhone.
            .animation(.snappy(duration: 0.32), value: [groups.now, groups.later, groups.done].map { section in
                section.map { "\($0.id)|\($0.isSnoozed(at: now))|\($0.isStarted(at: now))|\($0.isFinished)" }
            })
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
                    .contentTransition(.symbolEffect(.replace.downUp))
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
            if let source = task.source {
                Image(systemName: "arrow.down.app").foregroundStyle(.secondary).help("From \(source)")
            }
            if task.canSnooze(at: now) {
                Menu("Snooze") {
                    ForEach(SnoozeOption.allCases, id: \.self) { option in
                        Button(option.label) { model.snooze(task.id, minutes: option.minutes) }
                    }
                }
                .controlSize(.small)
            }
            if task.isOutstanding(at: now), !task.isStarted(at: now) {
                Button("Started") { model.start(task.id) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            if let link = task.link {
                Link("Open original", destination: link)
            }
            Button("Duplicate") { model.duplicateTask(task.id) }
            if task.isOutstanding(at: now), !task.isStarted(at: now) {
                Button("Started") { model.start(task.id) }
            }
            if task.canSnooze(at: now) {
                Menu("Snooze") {
                    ForEach(SnoozeOption.allCases, id: \.self) { option in
                        Button(option.label) { model.snooze(task.id, minutes: option.minutes) }
                    }
                }
            }
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
        if task.isStarted(at: now), let startedAt = task.startedAt {
            let checkingIn = task.isWorking(at: now) ? "" : " · checking in"
            return "Started \(NagFormat.duration(now.timeIntervalSince(startedAt))) ago\(checkingIn)"
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
        self.init(task: task ?? NagTask(title: ""), original: task, startNow: task == nil)
    }

    /// Reviews a nag from a link before saving it.
    init(draft: NagDraft) {
        self.init(task: draft.task, original: draft.original, startNow: false)
    }

    private init(task: NagTask, original: NagTask?, startNow: Bool) {
        isNew = original == nil
        self.original = original
        _task = State(initialValue: task)
        _startNow = State(initialValue: startNow)
        _limitSnoozes = State(initialValue: task.style.maxSnoozes != nil)
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
                if task.source != nil || task.link != nil {
                    Section {
                        if let source = task.source {
                            LabeledContent("From", value: source)
                        }
                        if let link = task.link {
                            Link("Open original", destination: link)
                        }
                    }
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
                    if task.repeatRule == .everyNDays {
                        Stepper("Every \(task.repeatEvery) days", value: $task.repeatEvery, in: 1...365)
                    }
                    if task.repeatRule == .monthly {
                        Picker("On day", selection: $task.monthDay) {
                            ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Text("Months without that day use their last day.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    Picker("Tone", selection: $task.style.tone) {
                        Text("Use the default").tag(NagTone?.none)
                        ForEach(NagTone.allCases, id: \.self) { Text($0.label).tag(NagTone?.some($0)) }
                    }
                    Picker("Working time", selection: $task.style.workMinutes) {
                        ForEach([10, 15, 25, 30, 45, 60, 90], id: \.self) { Text(NagFormat.minutes($0)).tag($0) }
                    }
                    Toggle("Break through Focus", isOn: $task.style.breakThroughFocus)
                } header: {
                    Text("Nagging")
                } footer: {
                    Text("After you tap Started, Nag goes quiet for this long, then checks in.")
                        .foregroundStyle(.secondary)
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
