import Testing
@testable import Recents

/// The trackpad recogniser, driven by synthetic contact frames.
///
/// It is pure arithmetic over a stream of "how many fingers, where, and was a
/// button down", which makes it testable without a trackpad — and worth testing,
/// because every way it can be wrong looks the same from outside: nothing
/// happens, or something happens when it should not.
@Suite("TapRecognizer")
struct TapRecognizerTests {

    /// One frame. Positions are only needed for the travel test, so they default
    /// to a fixed spot: fingers that do not move.
    private func frame(
        _ fingers: Int, at time: Double, clicking: Bool = false,
        scrolling: Bool = false, x: Float = 0.5
    ) -> TouchFrame {
        TouchFrame(
            fingerCount: fingers,
            timestamp: time,
            positions: (0..<fingers).map { _ in MultitouchSupport.Point(x: x, y: 0.5) },
            isClicking: clicking,
            isScrolling: scrolling
        )
    }

    /// Fingers land, rest, and lift. Returns what the lift decided.
    @discardableResult
    private func tap(
        _ recognizer: inout TapRecognizer, fingers: Int, from start: Double = 1,
        clicking: Bool = false, scrolling: Bool = false, travellingTo x: Float = 0.5
    ) -> TapRecognizer.Outcome {
        _ = recognizer.accept(frame(fingers, at: start))
        _ = recognizer.accept(frame(
            fingers, at: start + 0.05, clicking: clicking, scrolling: scrolling, x: x
        ))
        return recognizer.accept(frame(0, at: start + 0.1))
    }

    private func isRecognised(_ outcome: TapRecognizer.Outcome) -> Bool {
        if case .recognised = outcome { return true }
        return false
    }

    // MARK: - The shape itself

    @Test("Two fingers down and up, going nowhere, is the gesture")
    func aCleanTwoFingerTapFires() {
        var recognizer = TapRecognizer(fingerCount: 2)
        #expect(isRecognised(tap(&recognizer, fingers: 2)))
    }

    @Test("The wrong number of fingers is not the gesture")
    func theFingerCountMustMatch() {
        var recognizer = TapRecognizer(fingerCount: 2)
        #expect(!isRecognised(tap(&recognizer, fingers: 3)))
        #expect(!isRecognised(tap(&recognizer, fingers: 1)))
    }

    @Test("Fingers that travel are a swipe, not a tap")
    func travelIsRejected() {
        var recognizer = TapRecognizer(fingerCount: 2)
        #expect(!isRecognised(tap(&recognizer, fingers: 2, travellingTo: 0.9)))
    }

    @Test("Fingers held too long are a rest, not a tap")
    func holdingTooLongIsRejected() {
        var recognizer = TapRecognizer(fingerCount: 2)
        _ = recognizer.accept(frame(2, at: 1))
        #expect(!isRecognised(recognizer.accept(frame(0, at: 1 + 5))))
    }

    // MARK: - A click is not a tap

    @Test("A two-finger click is the secondary click and must never summon")
    func aClickIsNotATap() {
        // The whole reason two fingers can be offered at all: from the contacts
        // alone this episode is identical to the clean tap above.
        var recognizer = TapRecognizer(fingerCount: 2)
        #expect(!isRecognised(tap(&recognizer, fingers: 2, clicking: true)))
    }

    @Test("The click is remembered for the whole episode, not just the frame it was in")
    func theClickIsSticky() {
        // A press and its release both happen while the fingers are down, so by
        // the time they lift the button is up again.
        var recognizer = TapRecognizer(fingerCount: 2)
        _ = recognizer.accept(frame(2, at: 1))
        _ = recognizer.accept(frame(2, at: 1.05, clicking: true))
        _ = recognizer.accept(frame(2, at: 1.10, clicking: false))
        #expect(!isRecognised(recognizer.accept(frame(0, at: 1.15))))
    }

    @Test("A click does not poison the next tap")
    func theClickIsClearedBetweenEpisodes() {
        var recognizer = TapRecognizer(fingerCount: 2)
        _ = tap(&recognizer, fingers: 2, from: 1, clicking: true)
        #expect(isRecognised(tap(&recognizer, fingers: 2, from: 3)))
    }

    @Test("The rule holds at every finger count, not only at two")
    func clicksAreRejectedAtEveryCount() {
        var three = TapRecognizer(fingerCount: 3)
        #expect(!isRecognised(tap(&three, fingers: 3, clicking: true)))
        #expect(isRecognised(tap(&three, fingers: 3, from: 3)))
    }

    // MARK: - A scroll is not a tap

    @Test("Two fingers scrolling never summons, however little they travelled")
    func aScrollIsNotATap() {
        // The regression this exists for. Bound to two fingers without it, the
        // gesture fired every 0.2 to 0.9 seconds through ordinary reading: a
        // short scroll moves the centroid well under the travel limit, so the
        // contacts alone say "tap".
        var recognizer = TapRecognizer(fingerCount: 2)
        #expect(!isRecognised(tap(&recognizer, fingers: 2, scrolling: true)))
    }

    @Test("The scroll is remembered for the whole episode")
    func theScrollIsSticky() {
        // Scroll events stop arriving before the fingers lift, so an answer read
        // only at the lift frame would say "no scroll here".
        var recognizer = TapRecognizer(fingerCount: 2)
        _ = recognizer.accept(frame(2, at: 1))
        _ = recognizer.accept(frame(2, at: 1.05, scrolling: true))
        _ = recognizer.accept(frame(2, at: 1.10, scrolling: false))
        #expect(!isRecognised(recognizer.accept(frame(0, at: 1.15))))
    }

    @Test("A scroll does not poison the tap after it")
    func theScrollIsClearedBetweenEpisodes() {
        var recognizer = TapRecognizer(fingerCount: 2)
        _ = tap(&recognizer, fingers: 2, from: 1, scrolling: true)
        #expect(isRecognised(tap(&recognizer, fingers: 2, from: 3)))
    }

    // MARK: - The shape's own window

    @Test("Two fingers are held to a shorter window than the counts that do not rest")
    func twoFingersGetATighterWindow() {
        // Two fingers sit on a trackpad for no reason; three do not. Same
        // window for both would admit every idle hand.
        let two = SummonGesture.twoFingerTap.recognizer
        let three = SummonGesture.threeFingerTap.recognizer
        #expect(two.maxDuration < three.maxDuration)
        #expect(two.maxDuration == SummonGesture.twoFingerMaxDuration)
    }

    @Test("Two fingers resting past that window are not a tap")
    func restingTwoFingersAreRejected() {
        var recognizer = SummonGesture.twoFingerTap.recognizer
        _ = recognizer.accept(frame(2, at: 1))
        let resting = recognizer.accept(
            frame(0, at: 1 + SummonGesture.twoFingerMaxDuration + 0.1)
        )
        #expect(!isRecognised(resting))
    }

    // MARK: - Double taps

    @Test("A double tap needs both halves, and the first alone does nothing")
    func doubleTapNeedsTwo() {
        var recognizer = TapRecognizer(fingerCount: 3, tapCount: 2)
        let first = tap(&recognizer, fingers: 3, from: 1)
        if case .partial(let done, let total) = first {
            #expect(done == 1)
            #expect(total == 2)
        } else {
            Issue.record("the first tap should be partial, got \(first)")
        }
        #expect(isRecognised(tap(&recognizer, fingers: 3, from: 1.3)))
    }

    @Test("A clicked half does not count towards a double tap")
    func aClickedHalfDoesNotCount() {
        var recognizer = TapRecognizer(fingerCount: 3, tapCount: 2)
        _ = tap(&recognizer, fingers: 3, from: 1, clicking: true)
        #expect(!isRecognised(tap(&recognizer, fingers: 3, from: 1.3)))
    }
}

/// Whether this Mac has a trackpad at all — which is a different question from
/// whether the framework that reads one is present, and used not to be asked as
/// one.
@Suite("Trackpad availability")
struct TrackpadAvailabilityTests {

    /// `isAvailable` is read from the Settings body and from the status menu,
    /// and it now enumerates multitouch devices rather than merely checking that
    /// a private framework loaded. Both callers can ask many times over, so the
    /// call has to survive repetition — which a private-framework enumeration is
    /// not obviously guaranteed to do.
    ///
    /// The answer itself is hardware, so this asserts only that it is *the same*
    /// answer every time: a machine with a trackpad and a machine without one
    /// both pass, and a call that crashed, hung or flickered would not.
    @Test("Asking repeatedly gives one stable answer")
    func repeatedAsksAreStable() {
        let answers = (0..<200).map { _ in TrackpadGestureWatcher.isAvailable }
        #expect(Set(answers).count == 1)
    }
}
