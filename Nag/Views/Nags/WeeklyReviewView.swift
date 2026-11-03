import NagKit
import SwiftUI

/// A kind look back at a week: what got done, how long things took to get going, and one idea for a nag
/// that keeps running late. Nothing here counts what wasn't done.
struct WeeklyReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var history = CompletionHistory()
    /// A moment in the week being reviewed.
    @State private var weekDate = Date.now
    @State private var editing: NagTask?

    var body: some View {
        let now = Date.now
        let review = WeeklyReview.make(history: history, tasks: model.state.tasks, week: weekDate, now: now, calendar: model.calendar)
        List {
            Section {
                weekPicker(review, now: now)
            }

            if review.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nothing logged", systemImage: "leaf")
                    } description: {
                        Text("Whatever you finish shows up here. Every week is a fresh start.")
                    }
                }
            } else {
                Section {
                    LabeledContent("Done", value: "\(review.doneCount)")
                    if let delay = review.averageStartDelay {
                        LabeledContent("Time to get going", value: ReviewCopy.delay(delay))
                    }
                } footer: {
                    Text("Time to get going is how long after a nag came due you started it, or finished it.")
                }

                if let suggestion = review.suggestion {
                    Section("An idea") {
                        Text(suggestion.message(formatTime: formatTime))
                        if let task = model.state.task(suggestion.nagID) {
                            Button("Change “\(task.title)”") { editing = task }
                        }
                    }
                }

                Section("What got done") {
                    ForEach(review.entries) { entry in
                        LabeledContent(entry.title, value: entry.count == 1 ? "Once" : "\(entry.count) times")
                    }
                }

                if !review.slipping.isEmpty {
                    Section {
                        ForEach(review.slipping) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                Text("Usually got going \(ReviewCopy.delay(entry.averageStartDelay)) after it was due")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Tended to run late")
                    } footer: {
                        Text("Running late is normal. If a time never suits, moving it can make the nag easier to act on.")
                    }
                }
            }

            if let streak = ReviewCopy.streak(review.streak) {
                Section {
                    Label(streak, systemImage: "flame")
                } footer: {
                    Text("Quiet weeks pause the count. They never reset it.")
                }
            }
        }
        .navigationTitle("Weekly review")
        .accessibilityIdentifier("review.list")
        .onAppear { history = model.loadHistory() }
        // A nag done in a widget, on another device or from a notification while this is open.
        .onChange(of: model.state) { history = model.loadHistory() }
        .sheet(item: $editing) { task in
            TaskEditorView(task: task)
        }
    }

    private func weekPicker(_ review: WeeklyReview, now: Date) -> some View {
        let earliest = WeeklyReview.earliestWeek(in: history, calendar: model.calendar) ?? review.week.start
        let isCurrent = review.week.contains(now)
        return HStack {
            Button("Earlier week", systemImage: "chevron.left") { moveWeek(by: -1) }
                .disabled(review.week.start <= earliest)
            Spacer()
            Text(ReviewCopy.weekTitle(review.week, now: now, calendar: model.calendar))
                .font(.headline)
            Spacer()
            Button("Later week", systemImage: "chevron.right") { moveWeek(by: 1) }
                .disabled(isCurrent)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private func moveWeek(by weeks: Int) {
        weekDate = model.calendar.date(byAdding: .weekOfYear, value: weeks, to: weekDate) ?? weekDate
    }

    private func formatTime(_ minute: Int) -> String {
        let date = model.calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}
