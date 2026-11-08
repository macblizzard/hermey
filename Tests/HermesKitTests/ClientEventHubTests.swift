import XCTest
@testable import HermesKit

final class ClientEventHubTests: XCTestCase {
    func testEachSubscriberReceivesEveryEventInOrder() async {
        let hub = ClientEventHub()
        let first = hub.subscribe()
        let second = hub.subscribe()
        hub.yield(.messageDelta(session: "s", text: "one"))
        hub.yield(.messageDelta(session: "s", text: "two"))
        hub.finish()
        var a: [ClientEvent] = []
        var b: [ClientEvent] = []
        for await event in first { a.append(event) }
        for await event in second { b.append(event) }
        XCTAssertEqual(EventDigest.deltas(a), ["one", "two"])
        XCTAssertEqual(EventDigest.deltas(b), ["one", "two"])
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testCancellationRemovesOnlyOneSubscriberAndReplacementWorks() async {
        let hub = ClientEventHub()
        let cancelled = hub.subscribe()
        let survivor = hub.subscribe()
        let observer = Task { for await _ in cancelled {} }
        observer.cancel()
        await observer.value // a deterministic cancellation/termination fence, not a sleep
        XCTAssertEqual(hub.subscriberCount, 1)
        let replacement = hub.subscribe()
        hub.yield(.messageDelta(session: "s", text: "live"))
        hub.finish()
        var a: [ClientEvent] = []
        var b: [ClientEvent] = []
        for await event in survivor { a.append(event) }
        for await event in replacement { b.append(event) }
        XCTAssertEqual(EventDigest.deltas(a), ["live"])
        XCTAssertEqual(EventDigest.deltas(b), ["live"])
    }

    func testBufferIsBoundedAndRetainsNewestEvents() async {
        let hub = ClientEventHub(bufferLimit: 2)
        let stream = hub.subscribe()
        for text in ["old", "middle", "new"] {
            hub.yield(.messageDelta(session: "s", text: text))
        }
        hub.finish()
        var events: [ClientEvent] = []
        for await event in stream { events.append(event) }
        XCTAssertEqual(EventDigest.deltas(events), ["middle", "new"])
    }

    func testNoReplayWhenThereAreNoSubscribers() async {
        let hub = ClientEventHub()
        hub.yield(.messageDelta(session: "s", text: "before subscription"))
        let stream = hub.subscribe()
        hub.yield(.messageDelta(session: "s", text: "after subscription"))
        hub.finish()
        var events: [ClientEvent] = []
        for await event in stream { events.append(event) }
        XCTAssertEqual(EventDigest.deltas(events), ["after subscription"])
    }

    func testDroppingUnconsumedStreamRemovesSubscription() {
        let hub = ClientEventHub()
        var stream: AsyncStream<ClientEvent>? = hub.subscribe()
        XCTAssertNotNil(stream)
        XCTAssertEqual(hub.subscriberCount, 1)
        stream = nil
        XCTAssertEqual(hub.subscriberCount, 0)
    }

    func testHubDeinitFinishesObserversWithoutRetainCycle() async {
        var hub: ClientEventHub? = ClientEventHub()
        weak var weakHub = hub
        let stream = hub!.subscribe()
        hub = nil
        XCTAssertNil(weakHub)
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNil(event)
    }

    func testSubscribeAfterFinishImmediatelyEnds() async {
        let hub = ClientEventHub()
        hub.finish()
        hub.finish() // idempotent cleanup
        var iterator = hub.subscribe().makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertNil(event)
        XCTAssertEqual(hub.subscriberCount, 0)
    }
}
