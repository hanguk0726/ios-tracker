import XCTest
@testable import OpenReplay

// MARK: - Batches must reach the session that produced them
//
// Field data (2026-11-04, 6 of 38 iOS sessions over four days): the last batch of a
// session — written to lateMessages.dat when the app went to background — was
// uploaded on the next launch under the NEW session's token, so it sat in front of
// the new recording with a higher index and the replayer discarded everything after
// it. One more session got the same batch twice from foreground resumes.

final class LateMessageSessionTests: XCTestCase {
    private var dir: URL!
    private var token: String? = "T1"
    private var lateSent: [(content: Data, token: String?)] = []
    private var heldCompletions: [(Bool, Bool) -> Void] = []

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("late-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        token = "T1"
        lateSent = []
        heldCompletions = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var lateFile: URL { dir.appendingPathComponent("lateMessages.dat") }

    /// A collector for one app process. Late sends are recorded and fail (so the
    /// file is not removed by the send itself); batch sends are held open.
    private func makeCollector() -> MessageCollector {
        let collector = MessageCollector(lateDirectory: dir)
        collector.lateSender = { [unowned self] content, token, done in
            self.lateSent.append((content, token))
            done(false)
        }
        collector.messageSender = { [unowned self] _, done in
            self.heldCompletions.append(done)
        }
        collector.tokenAtStart = { [unowned self] in self.token }
        collector.currentToken = { [unowned self] in self.token }
        return collector
    }

    /// Going to background with one message queued writes the late file and starts
    /// the upload, whose completion stays held.
    private func backgroundWithQueuedMessage(_ collector: MessageCollector) {
        collector.sendRawMessage(Data([0x01, 0x02, 0x03]))
        collector.pause()
        collector.waitForQueue()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lateFile.path), "precondition: late file written on background")
    }

    func testLateFileIsSentWithTheTokenOfTheSessionThatWroteIt() {
        let first = makeCollector()
        first.start()
        backgroundWithQueuedMessage(first)
        first.stop()

        // Next launch: a new session (new token) is up before the collector starts.
        token = "T2"
        let next = makeCollector()
        next.start()
        next.waitForQueue()
        next.stop()

        XCTAssertEqual(lateSent.map { $0.token }, ["T1"])
    }

    func testLateFileWithoutAKnownOwnerIsDroppedNotSent() {
        try? Data([0x09]).write(to: lateFile)   // left by an SDK version that did not record the owner
        let collector = makeCollector()
        collector.start()
        collector.waitForQueue()
        collector.stop()

        XCTAssertTrue(lateSent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateFile.path))
    }

    func testForegroundResumeDoesNotResendTheLateFile() {
        let collector = makeCollector()
        collector.start()
        backgroundWithQueuedMessage(collector)

        collector.start()   // PerformanceListener.resume() → start()
        collector.waitForQueue()
        collector.stop()

        XCTAssertTrue(lateSent.isEmpty, "the queue still holds this batch; re-sending the file duplicates it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateFile.path))
    }

    func testBatchDeliveredAfterAResumeIsNotSentAgainOnTheNextLaunch() {
        let collector = makeCollector()
        collector.start()
        backgroundWithQueuedMessage(collector)

        collector.start()                    // back to foreground while the upload is in flight
        collector.waitForQueue()
        heldCompletions.first?(true, false)  // ...and it reaches the server
        collector.waitForQueue()
        collector.stop()

        let next = makeCollector()           // next launch
        next.start()
        next.waitForQueue()
        next.stop()

        XCTAssertTrue(lateSent.isEmpty, "the batch already reached the server; sending the file again duplicates it")
    }

    func testNewSessionInTheSameProcessStartsFromAnEmptyQueueAtIndexZero() {
        let collector = makeCollector()
        collector.start()
        collector.sendRawMessage(Data([0x01]))
        collector.flush()
        collector.waitForQueue()                 // first batch in flight (index advanced)
        collector.sendRawMessage(Data([0x02]))   // queued while no token
        collector.waitForQueue()

        collector.beginSession()
        collector.waitForQueue()
        XCTAssertEqual(collector.queuedMessageCount, 0)
        XCTAssertEqual(collector.nextIndexForTesting, 0)

        heldCompletions.first?(false, true)      // the old session's batch comes back retryable
        collector.waitForQueue()
        collector.stop()
        XCTAssertEqual(collector.queuedMessageCount, 0, "a retry from the previous session must not join the new one")
    }
}
