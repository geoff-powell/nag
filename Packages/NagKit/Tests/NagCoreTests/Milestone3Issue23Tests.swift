import Foundation
import Testing
@testable import NagCore

@Suite struct Milestone3Issue23Tests {
    let calendar = Fixture.calendar
    let now = Fixture.date(28, 12)

    private let shoes = RoutineStep(title: "Shoes on", estimateMinutes: 2)
    private let keys = RoutineStep(title: "Grab keys", estimateMinutes: 1)
    private let lock = RoutineStep(title: "Lock the door")

    private func routine(_ repeatRule: RepeatRule = .never, proof: CompletionProof = .none) -> NagTask {
        NagTask(
            title: "Out the door",
            startAt: Fixture.date(28, 8),
            repeatRule: repeatRule,
            proof: proof,
            steps: [shoes, keys, lock],
            now: Fixture.date(28, 7)
        )
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }

    private func decode<T: Decodable>(_ type: T.Type, _ object: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    // MARK: Model and coding

    @Test func plainNagsHaveNoSteps() {
        let task = NagTask(title: "Plain", now: now)
        #expect(task.routine == nil)
        #expect(!task.hasSteps)
        #expect(task.stepLabel == nil)
        #expect(task.currentStep == nil)
    }

    @Test func nagsFromOlderBuildsDecodeWithoutARoutine() throws {
        var object = try json(routine())
        object.removeValue(forKey: "routine")
        let decoded = try decode(NagTask.self, object)
        #expect(decoded.routine == nil)
        #expect(decoded.title == "Out the door")
    }

    @Test func routineRoundTripsThroughLocalStorage() throws {
        var task = routine()
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        let decoded = try JSONDecoder().decode(NagTask.self, from: JSONEncoder().encode(task))
        #expect(decoded == task)
        #expect(decoded.currentStep == keys)
    }

    @Test func aCorruptRoutineDoesNotMakeTheNagUndecodable() throws {
        var object = try json(routine())
        object["routine"] = "nonsense"
        let decoded = try decode(NagTask.self, object)
        #expect(decoded.routine == nil)
    }

    @Test func stepsDecodeWithDefaults() throws {
        let id = UUID()
        let step = try decode(RoutineStep.self, ["id": id.uuidString])
        #expect(step == RoutineStep(id: id, title: "", estimateMinutes: nil))
        let routine = try decode(NagRoutine.self, [String: Any]())
        #expect(routine.steps.isEmpty)
        #expect(routine.progress == nil)
    }

    // MARK: Stepping through

    @Test func completingAStepMovesOnAndStartsTheQuietWindow() {
        var task = routine()
        #expect(task.stepLabel == "Step 1 of 3")
        let last = task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        #expect(!last)
        #expect(task.currentStep == keys)
        #expect(task.stepLabel == "Step 2 of 3")
        #expect(task.startedAt == Fixture.date(28, 9))
        #expect(task.updatedAt == Fixture.date(28, 9))
        #expect(task.isWorking(at: Fixture.date(28, 9)))
    }

    @Test func eachStepExtendsTheQuietWindowByTheNextStepsEstimate() {
        var task = routine()
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        // Next step is "Grab keys", 1 minute.
        #expect(task.workingUntil() == Fixture.date(28, 9, 1))
        task.completeCurrentStep(at: Fixture.date(28, 9, 5), calendar: calendar)
        // "Lock the door" has no estimate: falls back to the nag's working time.
        #expect(task.workingUntil() == Fixture.date(28, 9, 35))
    }

    @Test func plainNagsKeepTheirWorkingTime() {
        var task = NagTask(title: "Plain", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        task.start(at: Fixture.date(28, 9))
        #expect(task.workingUntil() == Fixture.date(28, 9, 30))
    }

    @Test func theLastStepReportsItSoTheCallerCanComplete() {
        var task = routine()
        let result1 = task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        #expect(!result1)
        let result2 = task.completeCurrentStep(at: Fixture.date(28, 9, 1), calendar: calendar)
        #expect(!result2)
        let result3 = task.completeCurrentStep(at: Fixture.date(28, 9, 2), calendar: calendar)
        #expect(result3)
        #expect(task.allStepsDone)
        #expect(task.stepLabel == "All 3 steps done")
        #expect(task.completedAt == nil)
        // Pressing Next again still says "complete me".
        let result4 = task.completeCurrentStep(at: Fixture.date(28, 9, 3), calendar: calendar)
        #expect(result4)
    }

    @Test func stepsCannotBeDoneWhenTheNagCannotBeCompleted() {
        var task = routine(.daily)
        task.startAt = Fixture.date(29, 8)
        let result5 = task.completeCurrentStep(at: now, calendar: calendar)
        #expect(!result5)
        #expect(task.completedStepIDs.isEmpty)
    }

    @Test func progressResetsWhenARepeatingNagRollsOverAndComesBackOnUndo() {
        var task = routine(.daily)
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        task.completeCurrentStep(at: Fixture.date(28, 9, 1), calendar: calendar)
        task.completeCurrentStep(at: Fixture.date(28, 9, 2), calendar: calendar)
        task.complete(at: Fixture.date(28, 9, 2), calendar: calendar)
        #expect(task.startAt == Fixture.date(29, 8))
        #expect(task.currentStep == shoes)
        #expect(task.stepLabel == "Step 1 of 3")

        let result6 = task.undoCompletion(at: Fixture.date(28, 9, 3))
        #expect(result6)
        #expect(task.allStepsDone)
    }

    @Test func undoingTheFinalStepCompletionKeepsEarlierSteps() {
        var task = routine()
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        task.complete(at: Fixture.date(28, 9, 1), calendar: calendar)
        #expect(task.stepLabel == nil)
        task.undoCompletion(at: Fixture.date(28, 9, 2))
        #expect(task.currentStep == keys)
    }

    @Test func reopeningAOneOffStartsTheStepsAgain() {
        var task = routine()
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        task.complete(at: Fixture.date(28, 9, 1), calendar: calendar)
        task.reopen(at: Fixture.date(28, 10))
        #expect(task.currentStep == shoes)
        task.completeCurrentStep(at: Fixture.date(28, 10, 1), calendar: calendar)
        #expect(task.completedStepIDs == [shoes.id])
    }

    @Test func anOlderBuildCompletingTheNagStillResetsProgress() throws {
        var task = routine(.daily)
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        // An older build knows nothing about the routine, but completing moves startAt and lastCompletedAt.
        var object = try json(task)
        object.removeValue(forKey: "routine")
        var old = try decode(NagTask.self, object)
        old.complete(at: Fixture.date(28, 9, 5), calendar: calendar)
        let merged = TaskMerge.merge(task, old)
        #expect(merged.steps == task.steps)
        #expect(merged.currentStep == shoes)
    }

    @Test func removedStepsDropOutOfProgressAndReorderingKeepsIt() {
        var task = routine()
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        task.steps = [lock, shoes, keys]
        #expect(task.currentStep == lock)
        #expect(task.stepLabel == "Step 1 of 3")
        task.steps = [lock, keys]
        #expect(task.completedStepIDs.isEmpty)
    }

    // MARK: Estimated finish

    @Test func estimatedFinishSumsTheRemainingEstimates() {
        #expect(NagRoutine.estimatedFinish(remaining: [shoes, keys, lock], now: now) == Fixture.date(28, 12, 3))
        #expect(NagRoutine.estimatedFinish(remaining: [lock], now: now) == nil)
        #expect(NagRoutine.estimatedFinish(remaining: [], now: now) == nil)
        var task = routine()
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        #expect(task.estimatedFinish(at: now) == Fixture.date(28, 12, 1))
    }

    @Test func estimatesAreClamped() {
        #expect(RoutineStep(title: "x", estimateMinutes: 0).estimateMinutes == 1)
        #expect(RoutineStep(title: "x", estimateMinutes: 5000).estimateMinutes == 1440)
    }

    // MARK: Actions

    @Test func completeStepActionCompletesTheNagOnTheLastStep() throws {
        let task = routine()
        let store = try store(containing: NagState(tasks: [task]))
        #expect(try NagActions.completeStep(taskID: task.id, store: store, now: Fixture.date(28, 9), calendar: calendar) == .nextStep)
        #expect(try NagActions.completeStep(taskID: task.id, store: store, now: Fixture.date(28, 9, 1), calendar: calendar) == .nextStep)
        #expect(try NagActions.completeStep(taskID: task.id, store: store, now: Fixture.date(28, 9, 2), calendar: calendar) == .completed)
        let saved = try #require(store.load().task(task.id))
        #expect(saved.completedAt == Fixture.date(28, 9, 2))
        #expect(saved.canUndoCompletion(at: Fixture.date(28, 9, 3)))
    }

    @Test func completeStepActionStillNeedsTheKeyForTheFinalCompletion() throws {
        let key = UnlockKey(name: "Door", kind: .code, fingerprint: "door")
        var task = routine(proof: .scanKey(key.id))
        task.steps = [shoes]
        let store = try store(containing: NagState(tasks: [task], keys: [key]))
        let outcome = try NagActions.completeStep(taskID: task.id, store: store, now: Fixture.date(28, 9), calendar: calendar)
        #expect(outcome == .needsKeyScan(keyName: "Door"))
        let saved = try #require(store.load().task(task.id))
        #expect(saved.completedAt == nil)
        #expect(saved.allStepsDone)
        #expect(throws: NagActions.Failure.needsKeyScan(taskID: task.id, keyName: "Door")) {
            try NagActions.complete(taskID: task.id, store: store, now: Fixture.date(28, 9, 1), calendar: calendar)
        }
    }

    @Test func completeStepActionRejectsPlainNags() throws {
        let task = NagTask(title: "Plain", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        let store = try store(containing: NagState(tasks: [task]))
        #expect(throws: NagActions.Failure.cannotComplete) {
            try NagActions.completeStep(taskID: task.id, store: store, now: now, calendar: calendar)
        }
    }

    // MARK: Saving

    @Test func savingStampsStepEditsAndTidiesThem() {
        var state = NagState(tasks: [routine()])
        var edited = state.tasks[0]
        edited.steps.append(RoutineStep(title: "  Water bottle  "))
        edited.steps.append(RoutineStep(title: "   "))
        let saved = state.save(edited, now: now)
        #expect(saved.steps.map(\.title) == ["Shoes on", "Grab keys", "Lock the door", "Water bottle"])
        #expect(saved.routine?.updatedAt == now)

        var retitled = saved
        retitled.title = "Leave"
        #expect(state.save(retitled, now: Fixture.date(28, 13)).routine?.updatedAt == now)
    }

    @Test func savingAnOlderCopyKeepsStepsDoneMeanwhile() {
        var state = NagState(tasks: [routine()])
        let editorCopy = state.tasks[0]
        state.tasks[0].completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        let saved = state.save(editorCopy, now: Fixture.date(28, 9, 1))
        #expect(saved.currentStep == keys)
    }

    @Test func clearingEveryStepIsAnEditThatSyncs() {
        var state = NagState(tasks: [routine()])
        var edited = state.tasks[0]
        edited.steps = []
        let saved = state.save(edited, now: now)
        #expect(saved.routine?.steps == [])
        #expect(saved.routine?.updatedAt == now)
        #expect(!saved.hasSteps)
    }

    @Test func duplicatesGetFreshStepsAndNoProgress() {
        var task = routine()
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        let copy = task.duplicate(now: now)
        #expect(copy.steps.map(\.title) == task.steps.map(\.title))
        #expect(copy.steps.map(\.id) != task.steps.map(\.id))
        #expect(copy.currentStep?.title == "Shoes on")
    }

    // MARK: Merging

    @Test func stepEditsMergeOnTheirOwnTimestamp() {
        var phone = routine()
        phone.steps = [lock]
        phone.routine?.updatedAt = Fixture.date(28, 10)
        phone.updatedAt = Fixture.date(28, 10)
        var mac = routine()
        mac.title = "Leave"
        mac.updatedAt = Fixture.date(28, 11)

        let merged = TaskMerge.merge(phone, mac)
        #expect(merged.title == "Leave")
        #expect(merged.steps == [lock])
        #expect(TaskMerge.merge(mac, phone) == merged)
    }

    @Test func aStepLessCopyNeverWipesSteps() {
        var old = routine()
        old.routine = nil
        old.title = "Renamed on an old build"
        old.updatedAt = Fixture.date(28, 11)
        let merged = TaskMerge.merge(routine(), old)
        #expect(merged.title == "Renamed on an old build")
        #expect(merged.steps == [shoes, keys, lock])
    }

    @Test func concurrentStepsInTheSameOccurrenceAreBothKept() {
        let base = routine()
        var phone = base
        phone.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        var mac = base
        mac.steps = [keys, shoes, lock]
        mac.routine?.updatedAt = Fixture.date(28, 9, 1)
        mac.completeCurrentStep(at: Fixture.date(28, 9, 2), calendar: calendar)

        let merged = TaskMerge.merge(phone, mac)
        #expect(merged.completedStepIDs == [shoes.id, keys.id])
        #expect(merged.currentStep == lock)
        #expect(TaskMerge.merge(mac, phone) == merged)
    }

    @Test func progressFromALaterOccurrenceWins() {
        let early = StepProgress(occurrence: Fixture.date(28, 8), after: nil, done: [shoes.id], updatedAt: Fixture.date(28, 9))
        let later = StepProgress(occurrence: Fixture.date(29, 8), after: Fixture.date(28, 9), done: [keys.id], updatedAt: Fixture.date(29, 9))
        #expect(StepProgress.merge(early, later) == later)
        #expect(StepProgress.merge(later, early) == later)
        #expect(StepProgress.merge(nil, early) == early)
    }

    // MARK: Sync payload

    @Test func theNagsKeyCarriesNoRoutineForOlderBuilds() throws {
        var task = routine()
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        let (tasks, routines) = RoutineSidecar.split(SyncedTasks(tasks: [task]))
        let object = try json(tasks)
        let first = try #require((object["tasks"] as? [[String: Any]])?.first)
        #expect(first["routine"] == nil)
        #expect(routines[task.id.uuidString] == task.routine)
        #expect(RoutineSidecar.join(tasks, routines: routines).tasks == [task])
    }

    @Test func stepsSurviveAnOlderBuildRewritingTheNagsKey() throws {
        let local = routine()
        let (remoteTasks, sidecar) = RoutineSidecar.split(SyncedTasks(tasks: [local]))

        // An older build decodes the nags key, edits a nag, and writes back what it knows.
        var objects = try json(remoteTasks)
        var tasks = objects["tasks"] as! [[String: Any]]
        tasks[0]["title"] = "Renamed elsewhere"
        tasks[0]["updatedAt"] = Fixture.date(28, 11).timeIntervalSinceReferenceDate
        objects["tasks"] = tasks
        let rewritten = try decode(SyncedTasks.self, objects)

        // A fresh device with nothing local still gets the steps back from the sidecar.
        let remote = RoutineSidecar.join(rewritten, routines: sidecar)
        let merged = TaskMerge.merge(SyncedTasks(), remote, now: now)
        #expect(merged.tasks[0].title == "Renamed elsewhere")
        #expect(merged.tasks[0].steps == [shoes, keys, lock])
    }

    @Test func sidecarKeepsRoutinesWhoseNagHasNotArrivedButDropsDeletedOnes() {
        let pending = NagRoutine(steps: [shoes], updatedAt: now)
        let deletedID = UUID().uuidString
        let merged = SyncedTasks(tasks: [routine()], deleted: [deletedID: now])
        let pendingID = UUID().uuidString
        let routines = RoutineSidecar.routines(for: merged, keeping: [pendingID: pending, deletedID: pending])
        #expect(routines[pendingID] == pending)
        #expect(routines[deletedID] == nil)
        #expect(routines[merged.tasks[0].id.uuidString] != nil)
    }

    // MARK: Notifications

    @Test func notificationsMentionTheCurrentStep() throws {
        var task = routine()
        task.completeCurrentStep(at: Fixture.date(28, 9), calendar: calendar)
        let plan = NagPlanner(calendar: calendar).plan(tasks: [task], quietHours: .init(), now: now)
        let body = try #require(plan.notifications.first?.body)
        #expect(body.hasPrefix("Step 2 of 3: Grab keys\n"))
    }

    @Test func movingToTheNextStepChangesTheNotification() {
        var task = routine()
        let before = NagPlanner(calendar: calendar).plan(tasks: [task], quietHours: .init(), now: now)
        task.routine?.progress = StepProgress(occurrence: task.startAt, after: nil, done: [shoes.id], updatedAt: now)
        let after = NagPlanner(calendar: calendar).plan(tasks: [task], quietHours: .init(), now: now)
        #expect(before.notifications.map(\.identifier) != after.notifications.map(\.identifier))
    }

    @Test func plainNagNotificationsAreUnchanged() {
        let task = NagTask(title: "Plain", startAt: Fixture.date(28, 8), now: Fixture.date(28, 7))
        let plan = NagPlanner(calendar: calendar).plan(tasks: [task], quietHours: .init(), now: now)
        #expect(plan.notifications.allSatisfy { !$0.body.contains("Step") })
    }

    private func store(containing state: NagState) throws -> SharedStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = SharedStore(directory: directory)
        store.update { $0 = state }
        return store
    }
}
