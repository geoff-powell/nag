#if os(iOS)
import AlarmKit
import AppIntents
import Foundation
import NagCore
import SwiftUI

public struct NagAlarmIntents: AppIntentsPackage {}

@available(iOS 26, *)
public enum NagAlarmSync {
    private static let recordsKey = "scheduledNagAlarms"

    private struct Request: Codable, Equatable {
        let occurrence: Date
        let start: Date
        let mode: NagAlarmMode
        let date: Date
        let title: String
        let canSnooze: Bool

        func matchesOccurrence(_ other: Self) -> Bool {
            occurrence == other.occurrence && start == other.start && mode == other.mode
        }
    }

    private struct Record: Codable {
        let id: UUID
        let request: Request
        let fireAt: Date
    }

    @MainActor
    public static func requestAuthorizationIfNeeded() async {
        let manager = AlarmManager.shared
        guard manager.authorizationState == .notDetermined else { return }
        do {
            _ = try await manager.requestAuthorization()
        } catch {
            NagLog.error("Couldn't request alarm authorization: \(error)")
        }
    }

    @MainActor
    static func apply(state: NagState, now: Date, calendar: Calendar) async {
        let manager = AlarmManager.shared
        guard manager.authorizationState == .authorized else { return }
        do {
            let alarms = try manager.alarms
            let activeIDs = Set(alarms.map(\.id))
            let defaults = UserDefaults.standard
            var records = defaults.data(forKey: recordsKey)
                .flatMap { try? JSONDecoder().decode([UUID: Record].self, from: $0) } ?? [:]
            let quietHours = state.settings.quietHours
            let requests = Dictionary(uniqueKeysWithValues: state.tasks.compactMap { task -> (UUID, Request)? in
                guard let start = task.nagStart,
                      let date = task.alarmDate(
                        quietHours: quietHours, focusFilter: state.settings.focusFilter, calendar: calendar
                      ) else { return nil }
                return (task.id, Request(
                    occurrence: task.startAt, start: start, mode: task.style.alarmMode,
                    date: date, title: task.title, canSnooze: (task.snoozesLeft ?? 1) > 0
                ))
            })
            let existingTaskIDs = Set(state.tasks.map(\.id))

            // Keep unchanged alarms and cancel alarms for edited, deferred, or finished nags.
            let keptIDs = Set(records.compactMap { taskID, record -> UUID? in
                guard let request = requests[taskID] else { return nil }
                if request == record.request { return record.id }
                if record.fireAt <= now, request.matchesOccurrence(record.request) { return record.id }
                return nil
            })
            for alarm in alarms where !keptIDs.contains(alarm.id) {
                do {
                    try manager.cancel(id: alarm.id)
                } catch {
                    // The user may have stopped the alarm between the read and cancellation.
                    if try manager.alarms.contains(where: { $0.id == alarm.id }) { throw error }
                }
            }

            records = records.filter { taskID, record in
                existingTaskIDs.contains(taskID) && (keptIDs.contains(record.id) || record.fireAt <= now)
            }
            for (taskID, request) in requests.sorted(by: { $0.value.date < $1.value.date }) {
                if let record = records[taskID], request.matchesOccurrence(record.request) {
                    if keptIDs.contains(record.id), activeIDs.contains(record.id) { continue }
                    // Dismissing a one-shot alarm must not make the next sync ring it again.
                    if record.fireAt <= now { continue }
                }

                let fireAt = quietHours.nextAllowed(
                    after: max(request.date, Date.now.addingTimeInterval(3)), calendar: calendar
                )
                let id = UUID()
                do {
                    try await schedule(id: id, taskID: taskID, request: request, fireAt: fireAt)
                    records[taskID] = Record(id: id, request: request, fireAt: fireAt)
                    defaults.set(try JSONEncoder().encode(records), forKey: recordsKey)
                } catch {
                    NagLog.error("Couldn't schedule nag alarm: \(error)")
                }
            }
            defaults.set(try JSONEncoder().encode(records), forKey: recordsKey)
        } catch {
            NagLog.error("Couldn't reconcile nag alarms: \(error)")
        }
    }

    @MainActor
    private static func schedule(id: UUID, taskID: UUID, request: Request, fireAt: Date) async throws {
        let title = LocalizedStringResource(stringLiteral: request.title)
        let snooze = request.canSnooze
            ? AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz")
            : nil
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = .init(title: title, secondaryButton: snooze, secondaryButtonBehavior: snooze == nil ? nil : .custom)
        } else {
            alert = .init(
                title: title,
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"),
                secondaryButton: snooze,
                secondaryButtonBehavior: snooze == nil ? nil : .custom
            )
        }
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert), metadata: NagAlarmMetadata(), tintColor: .accentColor
        )
        let intent = request.canSnooze ? SnoozeNagAlarmIntent(taskID: taskID, start: request.start) : nil
        _ = try await AlarmManager.shared.schedule(
            id: id, configuration: .alarm(schedule: .fixed(fireAt), attributes: attributes, secondaryIntent: intent)
        )
    }
}

@available(iOS 26, *)
private struct NagAlarmMetadata: AlarmMetadata {}

@available(iOS 26, *)
struct SnoozeNagAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Snooze nag alarm"
    static let isDiscoverable = false

    @Parameter(title: "Nag ID") var taskID: String
    @Parameter(title: "Nag start") var start: Date

    init() {}

    init(taskID: UUID, start: Date) {
        self.taskID = taskID.uuidString
        self.start = start
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { return .result() }
        let now = Date.now
        let expectedStart = start
        SharedStore.shared.update { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }),
                  let currentStart = state.tasks[index].nagStart,
                  abs(currentStart.timeIntervalSince(expectedStart)) < 1,
                  state.tasks[index].style.alarmMode != .off else { return }
            _ = state.tasks[index].snooze(at: now)
        }
        await NagEngine.sync()
        return .result()
    }
}
#endif
