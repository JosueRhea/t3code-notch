import Foundation
import Testing
@testable import T3Notch

@Suite struct WireTests {
    private func parse(_ message: [String: Any]) -> [StreamValue] {
        let data = try! JSONSerialization.data(withJSONObject: message)
        guard case .chunk(_, let values)? = Incoming.parse(data) else { return [] }
        return values
    }

    @Test func terminalTailStripsEscapesAndCarriageReturns() {
        let raw = "\u{1B}[32m✓\u{1B}[0m compiled\r\nDownloading 10%\rDownloading 55%\rDownloading 100%\n\u{1B}]0;title\u{07}\nwarn: slow\n\n"
        #expect(ThreadStore.tailLines(raw, 4) == ["✓ compiled", "Downloading 100%", "warn: slow"])
    }

    @Test func outputFramesParse() {
        let values = parse(["_tag": "Chunk", "requestId": "9",
                            "values": [["kind": "append", "text": "hi\n", "truncated": false, "running": true]]])
        #expect(values.first?.output?.replace == false)
        #expect(values.first?.output?.text == "hi\n")
    }

    @Test func checkpointLineCountsSumFiles() {
        let item: [String: Any] = ["id": "c1", "type": "checkpoint", "ordinal": 5, "runId": "run:1",
                                   "files": [["path": "a", "kind": "modified", "additions": 13, "deletions": 49],
                                             ["path": "b", "kind": "added", "additions": 2, "deletions": 0]]]
        let values = parse(["_tag": "Chunk", "requestId": "3",
                            "values": [["kind": "event", "sequence": 1,
                                        "event": ["type": "turn-item.updated", "payload": item]]]])
        guard case .turnItem(let t)? = values.first?.thread else { Issue.record("no turn item"); return }
        #expect(t.linesAdded == 15)
        #expect(t.linesRemoved == 49)
    }

    @Test func emptyCheckpointMeansNoChanges() {
        let item: [String: Any] = ["id": "c2", "type": "checkpoint", "ordinal": 6, "runId": "run:2", "files": [] as [Any]]
        let values = parse(["_tag": "Chunk", "requestId": "3",
                            "values": [["kind": "event", "sequence": 1,
                                        "event": ["type": "turn-item.updated", "payload": item]]]])
        guard case .turnItem(let t)? = values.first?.thread else { Issue.record("no turn item"); return }
        #expect(t.linesAdded == 0)
        #expect(t.linesRemoved == 0)
    }

    @Test func pullRequestChecksAndReview() {
        let thread: [String: Any] = [
            "id": "t1", "projectId": "p", "title": "x", "status": "completed", "latestRunId": "r",
            "lineage": ["parentThreadId": NSNull()], "updatedAt": "2026-10-27T20:00:00.000Z",
            "pullRequests": [
                ["number": 74, "url": "https://github.com/o/r/pull/74", "source": "agent",
                 "snapshot": ["state": "open", "isDraft": false, "checksState": "failing",
                              "reviewDecision": "changes-requested", "mergeability": "conflicting"]],
                ["number": 75, "url": "u", "source": "stack-dismissed", "snapshot": ["state": "open"]],
            ],
        ]
        let values = parse(["_tag": "Chunk", "requestId": "1",
                            "values": [["kind": "thread.updated", "sequence": 1, "location": "active", "thread": thread]]])
        guard case .threadUpdated(let t)? = values.first?.shell else { Issue.record("no thread"); return }
        #expect(t.pr?.number == 74) // dismissed stack entry ignored
        #expect(t.pr?.checks == .failing)
        #expect(t.pr?.review == .changesRequested)
        #expect(t.pr?.conflicting == true)
    }

    @Test func usageLimitIsAFailureWithAResetTime() {
        let thread: [String: Any] = [
            "id": "t1", "projectId": "p", "title": "x", "status": "failed", "latestRunId": "r",
            "lineage": ["parentThreadId": NSNull()], "updatedAt": "2026-10-27T20:00:00.000Z",
            "lastErrorClass": "usage_limit", "usageLimitResetAt": "2026-10-27T22:00:00.000Z",
        ]
        let values = parse(["_tag": "Chunk", "requestId": "1",
                            "values": [["kind": "thread.updated", "sequence": 1, "location": "active", "thread": thread]]])
        guard case .threadUpdated(let t)? = values.first?.shell else { Issue.record("no thread"); return }
        #expect(t.status == .failed)
        #expect(t.usageLimited)
        #expect(t.usageLimitResetAt != nil)
    }
}

@Suite struct DiffCountTests {
    @Test func claudeStructuredPatch() {
        let diff = #"{"type":"update","filePath":"a","structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":4,"lines":[" keep","-old","+new","+added"]}]}"#
        #expect(Incoming.lineCounts(diffStr: diff)! == (2, 1))
    }

    @Test func claudeNewFileCountsAllLinesAdded() {
        let diff = #"{"type":"create","filePath":"a","content":"one\ntwo\nthree","structuredPatch":[]}"#
        #expect(Incoming.lineCounts(diffStr: diff)! == (3, 0))
    }

    @Test func unifiedDiffIgnoresFileHeaders() {
        let diff = "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-a\n+b\n c\n"
        #expect(Incoming.lineCounts(diffStr: diff)! == (1, 1))
    }

    @Test func unknownFormatIsNil() {
        #expect(Incoming.lineCounts(diffStr: "not a diff") == nil)
    }
}
