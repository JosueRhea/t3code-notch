import Foundation
import Testing
@testable import T3Notch

/// The notch's status must match T3's sidebar pill (`resolveThreadStatusPill` in
/// t3code apps/web/src/components/Sidebar.logic.ts). These feed real wire-shaped
/// `thread.updated` stream chunks through the parser, like the server sends them.
@Suite struct StatusTests {
    private func shell(_ fields: [String: Any]) -> ShellThread {
        var thread: [String: Any] = [
            "id": "t1", "projectId": "p1", "title": "A thread",
            "status": "idle", "latestRunId": "run:1", "activeProviderThreadId": NSNull(),
            "activityRunStatus": NSNull(), "pendingRuntimeRequest": NSNull(),
            "updatedAt": "2026-10-27T20:00:00.000Z", "interactionMode": "default",
            "hasActionableProposedPlan": false, "pendingBackgroundTasks": [] as [Any],
            "lineage": ["parentThreadId": NSNull(), "relationshipToParent": NSNull()],
            "archivedAt": NSNull(), "deletedAt": NSNull(),
        ]
        thread.merge(fields) { _, new in new }
        let message: [String: Any] = [
            "_tag": "Chunk", "requestId": "1",
            "values": [["kind": "thread.updated", "sequence": 1, "location": "active", "thread": thread]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: message)
        guard case .chunk(_, let values)? = Incoming.parse(data),
              case .threadUpdated(let t)? = values.first?.shell else {
            Issue.record("didn't parse as thread.updated")
            fatalError()
        }
        return t
    }

    @Test func runningIsWorking() {
        #expect(shell(["status": "running", "activityRunStatus": "running"]).status == .working)
    }

    @Test func waitingRunStatusIsStillWorking() {
        // T3: a run in "waiting" has ended its provider turn and is draining effects; pill says Working.
        #expect(shell(["status": "waiting", "activityRunStatus": "waiting"]).status == .working)
    }

    @Test func blockedOnAnotherThreadIsWaiting() {
        #expect(shell(["status": "running", "activityRunStatus": "running", "blockedOnThreadWait": true]).status == .waiting)
    }

    @Test func backgroundSubagentHoldsCompletionAsWaiting() {
        let t = shell(["status": "completed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "pendingBackgroundTasks": [["kind": "subagent", "id": "n1"]]])
        #expect(t.status == .waiting)
    }

    @Test func backgroundCommandDoesNotHoldCompletion() {
        let t = shell(["status": "completed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "lastVisitedAt": "2026-10-27T21:00:00.000Z",
                       "pendingBackgroundTasks": [["kind": "command", "id": "n1"]]])
        #expect(t.status == .idle)
    }

    @Test func awaitedBackgroundCommandIsWaiting() {
        // Newer T3: work the agent marks `awaited` holds the thread as Waiting whatever its kind.
        let t = shell(["status": "completed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "lastVisitedAt": "2026-10-27T20:00:00.000Z",
                       "pendingBackgroundTasks": [["taskId": "b1", "kind": "command", "awaited": true,
                                                   "description": "Wait for Vercel web deploy"]]])
        #expect(t.status == .waiting)
        #expect(t.waitingOn == "Wait for Vercel web deploy")
    }

    @Test func pendingGuestMessageIsGuestRequest() {
        let t = shell(["status": "completed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "pendingGuestMessageCount": 2])
        #expect(t.status == .guestRequest)
    }

    @Test func approvalOutranksGuestRequest() {
        let t = shell(["status": "running", "activityRunStatus": "running", "pendingGuestMessageCount": 1,
                       "pendingRuntimeRequest": ["id": "r1", "kind": "command", "createdAt": "2026-10-27T20:00:00.000Z"]])
        #expect(t.status == .pendingApproval)
    }

    @Test(arguments: ["preparing", "starting", "queued"])
    func startingUpIsConnecting(_ status: String) {
        #expect(shell(["status": status, "activityRunStatus": status]).status == .connecting)
    }

    @Test func approvalRequestIsPendingApproval() {
        let t = shell(["status": "running", "activityRunStatus": "running",
                       "pendingRuntimeRequest": ["id": "r1", "kind": "command", "createdAt": "2026-10-27T20:00:00.000Z"]])
        #expect(t.status == .pendingApproval)
        #expect(t.pendingRequestId == "r1")
    }

    @Test func authRefreshIsNotAnApproval() {
        let t = shell(["status": "running", "activityRunStatus": "running",
                       "pendingRuntimeRequest": ["id": "r1", "kind": "auth_refresh", "createdAt": "2026-10-27T20:00:00.000Z"]])
        #expect(t.status == .working)
    }

    @Test func blockingQuestionIsAwaitingInput() {
        let t = shell(["status": "running", "activityRunStatus": "running",
                       "pendingRuntimeRequest": ["id": "r1", "kind": "user_input", "createdAt": "2026-10-27T20:00:00.000Z"]])
        #expect(t.status == .awaitingInput)
    }

    @Test func nonBlockingQuestionWhileWorkingStaysWorking() {
        let t = shell(["status": "running", "activityRunStatus": "running",
                       "pendingRuntimeRequest": ["id": "r1", "kind": "user_input", "blocking": false,
                                                 "createdAt": "2026-10-27T20:00:00.000Z"]])
        #expect(t.status == .working)
    }

    @Test func nonBlockingQuestionAfterRunEndsIsAwaitingInput() {
        let t = shell(["status": "completed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "pendingRuntimeRequest": ["id": "r1", "kind": "user_input", "blocking": false,
                                                 "createdAt": "2026-10-27T20:00:00.000Z"]])
        #expect(t.status == .awaitingInput)
    }

    @Test func unseenFailureIsFailed() {
        let t = shell(["status": "failed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "lastVisitedAt": "2026-10-27T19:00:00.000Z"])
        #expect(t.status == .failed)
    }

    @Test func neverOpenedFailureIsFailed() {
        #expect(shell(["status": "failed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z"]).status == .failed)
    }

    @Test func seenFailureHasNoPill() {
        let t = shell(["status": "failed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "lastVisitedAt": "2026-10-27T21:00:00.000Z"])
        #expect(t.status == .idle)
    }

    @Test func unseenCompletionIsCompleted() {
        let t = shell(["status": "completed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "lastVisitedAt": "2026-10-27T19:00:00.000Z"])
        #expect(t.status == .completed)
    }

    @Test func seenCompletionHasNoPill() {
        let t = shell(["status": "completed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "lastVisitedAt": "2026-10-27T21:00:00.000Z"])
        #expect(t.status == .idle)
    }

    @Test func neverVisitedCompletionHasNoPill() {
        // hasUnseenCompletion() needs a lastVisitedAt; automation threads nobody opened stay quiet.
        #expect(shell(["status": "completed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z"]).status == .idle)
    }

    @Test func idleStatusFallsBackToUpdatedAtAsCompletion() {
        // Older servers omit latestRunCompletedAt; presentThreadShell uses updatedAt for terminal runs.
        let t = shell(["status": "idle", "updatedAt": "2026-10-27T20:00:00.000Z",
                       "lastVisitedAt": "2026-10-27T19:00:00.000Z"])
        #expect(t.status == .completed)
    }

    @Test func settledPlanIsPlanReady() {
        let t = shell(["status": "completed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "interactionMode": "plan", "hasActionableProposedPlan": true])
        #expect(t.status == .planReady)
    }

    @Test func planWhileRunningIsWorking() {
        let t = shell(["status": "running", "activityRunStatus": "running",
                       "interactionMode": "plan", "hasActionableProposedPlan": true])
        #expect(t.status == .working)
    }

    @Test func liveAppOwnedSubagentForwardsItsQuestion() {
        let t = shell(["status": "running", "activityRunStatus": "running", "creationSource": "web",
                       "lineage": ["parentThreadId": "parent", "relationshipToParent": "subagent"],
                       "pendingRuntimeRequest": ["id": "r1", "kind": "user_input", "createdAt": "2026-10-27T20:00:00.000Z"]])
        #expect(t.subagentRequest == .awaitingInput)
        #expect(t.parentId == "parent")
    }

    @Test func providerNativeSubagentDoesNotForward() {
        let t = shell(["status": "running", "activityRunStatus": "running", "creationSource": "provider",
                       "lineage": ["parentThreadId": "parent", "relationshipToParent": "subagent"],
                       "pendingRuntimeRequest": ["id": "r1", "kind": "command", "createdAt": "2026-10-27T20:00:00.000Z"]])
        #expect(t.subagentRequest == nil)
    }

    @Test func runPhaseDrivesSoundsEvenAfterSeen() {
        // T3 hides "Completed" once seen, but a finished run must still read as completed for the click.
        let t = shell(["status": "completed", "latestRunCompletedAt": "2026-10-27T20:00:00.000Z",
                       "lastVisitedAt": "2026-10-27T21:00:00.000Z"])
        #expect(t.status == .idle)
        #expect(t.phase == .completed)
    }
}
