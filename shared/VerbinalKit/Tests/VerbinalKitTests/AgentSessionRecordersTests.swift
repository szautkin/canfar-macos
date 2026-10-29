// SPDX-License-Identifier: MPL-2.0

import MCPCore
import XCTest
@testable import VerbinalKit

/// Plan 52 C: the session log and the list of connected assistants hear
/// the same bridge, through one recorder.
final class AgentSessionRecordersTests: XCTestCase {
    private actor Heard: AgentSessionRecorder {
        let token: Int?
        var events: [String] = []
        init(token: Int?) { self.token = token }

        func opened(_ session: UUID, client: String, relay: RelayIdentity?) { events.append("opened \(client) \(relay?.pid ?? 0)") }
        func callBegan(_ session: UUID, call: UUID, tool: String) { events.append("began \(tool)") }
        func callEnded(_ session: UUID, call: UUID, tool: String, traced: AIToolRouter.Traced) -> Int? {
            events.append("ended \(tool)")
            return token
        }
        func closed(_ session: UUID) { events.append("closed") }
    }

    func testEachHearsEveryEventAndTheFirstTokenIsAnswered() async {
        let log = Heard(token: 7), list = Heard(token: nil)
        let both = AgentSessionRecorders([log, list])
        let session = UUID(), call = UUID()
        let relay = RelayIdentity(pid: 42, started: Date(), parentPID: 41, parentName: nil, version: "1.4.2", build: nil, executable: "/v")
        await both.opened(session, client: "codex/0.9", relay: relay)
        await both.callBegan(session, call: call, tool: "describe_app")
        let token = await both.callEnded(session, call: call, tool: "describe_app",
                                         traced: AIToolRouter.Traced(result: .data(Data()), seconds: 0, trace: RequestTrace(parent: nil)))
        await both.closed(session)
        XCTAssertEqual(token, 7)
        for heard in [log, list] {
            let events = await heard.events
            XCTAssertEqual(events, ["opened codex/0.9 42", "began describe_app", "ended describe_app", "closed"])
        }
    }
}
