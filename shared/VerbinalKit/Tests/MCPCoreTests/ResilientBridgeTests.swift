// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MCPCore

/// The bridge an assistant launches must keep its session alive across the
/// app being closed, starting, and quitting (Windows 1.4.1 parity).
final class ResilientBridgeTests: XCTestCase {

    // MARK: - Harness

    /// Collects every frame one end of a transport receives.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [[String: Any]] = []

        init(_ transport: InMemoryTransport) {
            Task {
                for try await frame in transport.incoming {
                    if let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any] {
                        self.lock.withLock { self.frames.append(object) }
                    }
                }
            }
        }

        /// The first frame not yet taken that matches, waiting up to 2 s.
        func take(_ matches: @escaping ([String: Any]) -> Bool = { _ in true },
                  file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
            for _ in 0..<200 {
                let hit: [String: Any]? = lock.withLock {
                    guard let i = frames.firstIndex(where: matches) else { return nil }
                    return frames.remove(at: i)
                }
                if let hit { return hit }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("no matching frame arrived", file: file, line: line)
            throw CancellationError()
        }

        var isEmpty: Bool { lock.withLock { frames.isEmpty } }
    }

    /// The app side of every connection the bridge makes.
    private final class FakeApp: @unchecked Sendable {
        private let lock = NSLock()
        private var running = false
        /// How long each attempt takes — a stalled container read.
        private var delay: Duration = .zero
        private(set) var attempts = 0
        private(set) var links: [(end: InMemoryTransport, inbox: Inbox)] = []

        func setRunning(_ value: Bool) { lock.withLock { running = value } }
        func setDelay(_ value: Duration) { lock.withLock { delay = value } }
        var attemptCount: Int { lock.withLock { attempts } }
        var latest: (end: InMemoryTransport, inbox: Inbox)? { lock.withLock { links.last } }

        func connect() async -> (any MCPTransport)? {
            let wait = lock.withLock { delay }
            if wait > .zero { try? await Task.sleep(for: wait) }
            return lock.withLock {
                attempts += 1
                guard running else { return nil }
                let (bridgeEnd, appEnd) = InMemoryTransport.pair()
                links.append((appEnd, Inbox(appEnd)))
                return bridgeEnd
            }
        }
    }

    private let notRunning = "Verbinal is not running. Open it and turn on Allow external AI agents."
    /// The handshake says the app is closed, and how to start once it is running (plan 25 W).
    private var handshake: String { notRunning + " " + AgentSession.instructions }
    private var cacheURL: URL!

    override func setUp() {
        cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-tools-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func start(_ app: FakeApp, cached: [String] = []) -> (client: InMemoryTransport, inbox: Inbox, task: Task<Void, Never>) {
        let cache = ToolManifestCache(url: cacheURL)
        cache.save(cached.map { ToolDefinitionWire(name: $0, description: $0, inputSchema: .object(["type": .string("object")])) })
        let (clientEnd, bridgeEnd) = InMemoryTransport.pair()
        let bridge = ResilientBridge(
            client: bridgeEnd,
            connect: { await app.connect() },
            manifest: cache,
            configuration: .init(serverName: "Verbinal", serverVersion: "1.4.0",
                                 notRunningMessage: notRunning, instructions: AgentSession.instructions,
                                 reconnectInterval: .milliseconds(20),
                                 firstConnectGrace: .milliseconds(50)))
        let task = Task { await bridge.run() }
        return (clientEnd, Inbox(clientEnd), task)
    }

    private func send(_ transport: InMemoryTransport, _ json: String) async throws {
        try await transport.send(Data(json.utf8))
    }

    private let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"2.1"}}}"#
    private let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#

    private func id(_ n: Int) -> ([String: Any]) -> Bool { { ($0["id"] as? Int) == n } }
    private func method(_ m: String) -> ([String: Any]) -> Bool { { ($0["method"] as? String) == m } }
    private func result(_ frame: [String: Any]) -> [String: Any] { frame["result"] as? [String: Any] ?? [:] }

    // MARK: - Tests

    func testWhileClosedItShakesHandsListsTheLastToolsAndExplainsEveryCall() async throws {
        let app = FakeApp()
        let (client, inbox, task) = start(app, cached: ["get_fits_view", "run_search"])
        defer { task.cancel() }

        try await send(client, initialize)
        let hello = result(try await inbox.take(id(1)))
        XCTAssertEqual((hello["serverInfo"] as? [String: Any])?["name"] as? String, "Verbinal")
        let tools = (hello["capabilities"] as? [String: Any])?["tools"] as? [String: Any]
        XCTAssertEqual(tools?["listChanged"] as? Bool, true, "list_changed must be honoured once the app appears")
        XCTAssertEqual(hello["protocolVersion"] as? String, "2025-06-18")

        try await send(client, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let listed = (result(try await inbox.take(id(2)))["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(listed, ["get_fits_view", "run_search"])

        try await send(client, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_search","arguments":{}}}"#)
        let call = result(try await inbox.take(id(3)))
        XCTAssertEqual(call["isError"] as? Bool, true, "a tool error the assistant reads, not a protocol error")
        let text = ((call["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertEqual(text, notRunning)
    }

    func testWhenTheAppStartsItReplaysTheHandshakeAndAnnouncesTheToolList() async throws {
        let app = FakeApp()
        let (client, inbox, task) = start(app)
        defer { task.cancel() }
        try await send(client, initialize)
        _ = try await inbox.take(id(1))
        try await send(client, initialized)

        app.setRunning(true)
        let first = await waitForLink(app)
        var link = try XCTUnwrap(first)
        let replay = try await link.inbox.take(method("initialize"))
        let replayID = try XCTUnwrap(replay["id"] as? String)
        XCTAssertEqual(((replay["params"] as? [String: Any])?["clientInfo"] as? [String: Any])?["name"] as? String,
                       "claude-code", "the app sees the assistant's own handshake")
        try await send(link.end, #"{"jsonrpc":"2.0","id":"\#(replayID)","result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"Verbinal","version":"1.4.0"}}}"#)
        _ = try await link.inbox.take(method("notifications/initialized"))
        _ = try await inbox.take(method("notifications/tools/list_changed"))
        link = try XCTUnwrap(app.latest)

        // Relaying now; a tools/list answer refreshes the cache.
        try await send(client, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        _ = try await link.inbox.take(id(2))
        try await send(link.end, #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"describe_app","description":"d","inputSchema":{"type":"object"}}]}}"#)
        let listed = (result(try await inbox.take(id(2)))["tools"] as? [[String: Any]])?.first?["name"] as? String
        XCTAssertEqual(listed, "describe_app")
        XCTAssertEqual(ToolManifestCache(url: cacheURL).load().map(\.name), ["describe_app"])
    }

    func testTheAppQuittingMidCallAnswersTheCallThenExplainsLaterOnes() async throws {
        let app = FakeApp()
        app.setRunning(true)
        let (client, inbox, task) = start(app)
        defer { task.cancel() }
        let first = await waitForLink(app)
        let link = try XCTUnwrap(first)

        try await send(client, initialize)
        _ = try await link.inbox.take(id(1))
        try await send(link.end, #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"Verbinal","version":"1.4.0"}}}"#)
        _ = try await inbox.take(id(1))

        try await send(client, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"download_observation"}}"#)
        _ = try await link.inbox.take(id(5))
        app.setRunning(false)
        await link.end.close()

        let orphan = try await inbox.take(id(5))
        let error = try XCTUnwrap(orphan["error"] as? [String: Any])
        XCTAssertTrue((error["message"] as? String ?? "").contains("closed before answering tools/call"))

        try await send(client, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"run_search"}}"#)
        let later = try await inbox.take(id(6))
        XCTAssertEqual(result(later)["isError"] as? Bool, true)
    }

    func testAnAssistantTheAppRefusedIsNotAskedAgain() async throws {
        let app = FakeApp()
        let (client, inbox, task) = start(app)
        defer { task.cancel() }
        try await send(client, initialize)
        _ = try await inbox.take(id(1))

        app.setRunning(true)
        let first = await waitForLink(app)
        let link = try XCTUnwrap(first)
        let replay = try await link.inbox.take(method("initialize"))
        let replayID = try XCTUnwrap(replay["id"] as? String)
        try await send(link.end, #"{"jsonrpc":"2.0","id":"\#(replayID)","error":{"code":\#(JSONRPCErrorCode.sessionNotApproved),"message":"Client not approved by user."}}"#)

        try await Task.sleep(for: .milliseconds(200))
        let attempts = app.attemptCount
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.attemptCount, attempts, "a refused assistant must not re-prompt the user")
        try await send(client, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"x"}}"#)
        let call = try await inbox.take(id(2))
        XCTAssertEqual(result(call)["isError"] as? Bool, true)
    }

    /// A first attempt stuck longer than the grace must not hold the
    /// handshake; when it does connect, the handshake is replayed.
    func testAStalledFirstConnectDoesNotHoldTheHandshake() async throws {
        let app = FakeApp()
        app.setRunning(true)
        app.setDelay(.milliseconds(400))
        let (client, inbox, task) = start(app)
        defer { task.cancel() }

        try await send(client, initialize)
        let hello = try await inbox.take(id(1))
        XCTAssertEqual(result(hello)["instructions"] as? String, handshake, "answered by the bridge, in time")

        let late = await waitForLink(app)
        let link = try XCTUnwrap(late)
        let replay = try await link.inbox.take(method("initialize"))
        let replayID = try XCTUnwrap(replay["id"] as? String)
        try await send(link.end, #"{"jsonrpc":"2.0","id":"\#(replayID)","result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"Verbinal","version":"1.4.0"}}}"#)
        _ = try await inbox.take(method("notifications/tools/list_changed"))
    }

    private func waitForLink(_ app: FakeApp) async -> (end: InMemoryTransport, inbox: Inbox)? {
        for _ in 0..<200 {
            if let link = app.latest { return link }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    // MARK: - Every MCP version (plan 25 V)

    private let modernMeta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"future","version":"9"}}"#

    func testWhileClosedAModernClientIsAnsweredInItsOwnShape() async throws {
        let app = FakeApp()
        let (client, inbox, task) = start(app, cached: ["run_search"])
        defer { task.cancel() }

        try await send(client, #"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"# + modernMeta + "}}")
        let discovered = result(try await inbox.take(id(1)))
        XCTAssertEqual(discovered["resultType"] as? String, "complete")
        XCTAssertEqual((discovered["supportedVersions"] as? [String])?.first, "2026-07-28")
        XCTAssertEqual(discovered["instructions"] as? String, handshake, "how to start, once it is running")

        try await send(client, #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"# + modernMeta + "}}")
        let listed = result(try await inbox.take(id(2)))
        XCTAssertEqual(listed["resultType"] as? String, "complete")
        XCTAssertNotNil(listed["ttlMs"])
        XCTAssertEqual((listed["tools"] as? [[String: Any]])?.first?["name"] as? String, "run_search")

        try await send(client, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_search","arguments":{},"# + modernMeta + "}}")
        let called = result(try await inbox.take(id(3)))
        XCTAssertEqual(called["isError"] as? Bool, true)
        XCTAssertEqual(called["resultType"] as? String, "complete")

        try await send(client, #"{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"1900-01-01"}}}"#)
        let refused = try await inbox.take(id(4))
        XCTAssertEqual((refused["error"] as? [String: Any])?["code"] as? Int, -32022)
    }

    /// A modern client has no handshake to replay: its requests, and its
    /// cancellations, go straight to the app.
    func testAModernClientsRequestsAndCancellationsReachTheApp() async throws {
        let app = FakeApp()
        app.setRunning(true)
        let (client, _, task) = start(app)
        defer { task.cancel() }
        for _ in 0..<100 where app.latest == nil { try await Task.sleep(for: .milliseconds(10)) }
        let appSide = try XCTUnwrap(app.latest)

        try await send(client, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"run_search","arguments":{},"# + modernMeta + "}}")
        _ = try await appSide.inbox.take(id(7))
        try await send(client, #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#)
        _ = try await appSide.inbox.take(method("notifications/cancelled"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(appSide.inbox.isEmpty, "no handshake was replayed: there was none")
    }
}
