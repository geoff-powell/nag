import NagKit
import SwiftUI

/// A compact weekly review: what got done this week or an earlier one, and one gentle idea.
struct MacReviewView: View {
    @Environment(MacModel.self) private var model
    @State private var history = CompletionHistory()
    /// A moment in the week being reviewed.
    @State private var weekDate = Date.now

    var body: some View {
        let now = Date.now
        let review = WeeklyReview.make(history: history, tasks: model.state.tasks, week: weekDate, now: now, calendar: model.calendar)
        let earliest = WeeklyReview.earliestWeek(in: history, calendar: model.calendar) ?? review.week.start
        Form {
            Section {
                if review.isEmpty {
                    Text("Nothing logged. Whatever you finish shows up here, and every week is a fresh start.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Done", value: "\(review.doneCount)")
                    if let delay = review.averageStartDelay {
                        LabeledContent("Time to get going", value: ReviewCopy.delay(delay))
                    }
                }
                if let streak = ReviewCopy.streak(review.streak) {
                    Label(streak, systemImage: "flame")
                }
            } header: {
                HStack {
                    Text(ReviewCopy.weekTitle(review.week, now: now, calendar: model.calendar))
                    Spacer()
                    Button("Earlier week", systemImage: "chevron.left") { moveWeek(by: -1) }
                        .disabled(review.week.start <= earliest)
                    Button("Later week", systemImage: "chevron.right") { moveWeek(by: 1) }
                        .disabled(review.week.contains(now))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            } footer: {
                Text("Time to get going is how long after a nag came due you started it, or finished it. Quiet weeks pause the count; they never reset it.")
                    .foregroundStyle(.secondary)
            }

            if let suggestion = review.suggestion {
                Section("An idea") {
                    Text(suggestion.message(formatTime: formatTime))
                }
            }

            if !review.entries.isEmpty {
                Section("What got done") {
                    ForEach(review.entries) { entry in
                        LabeledContent(entry.title, value: entry.count == 1 ? "Once" : "\(entry.count) times")
                    }
                }
            }

            if !review.slipping.isEmpty {
                Section("Tended to run late") {
                    ForEach(review.slipping) { entry in
                        LabeledContent(entry.title, value: ReviewCopy.delay(entry.averageStartDelay))
                    }
                }
            }

            Section {
                Label("Completion history stays on this Mac. It isn't synced.", systemImage: "internaldrive")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Weekly review")
        .onAppear { history = model.loadHistory() }
        .onChange(of: model.state) { history = model.loadHistory() }
    }

    private func moveWeek(by weeks: Int) {
        weekDate = model.calendar.date(byAdding: .weekOfYear, value: weeks, to: weekDate) ?? weekDate
    }

    private func formatTime(_ minute: Int) -> String {
        let date = model.calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}
