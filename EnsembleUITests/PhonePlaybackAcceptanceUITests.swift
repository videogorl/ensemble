import XCTest

/// Scripted playback acceptance for a physical, signed-in iPhone (the SE). Opt-in:
/// `TEST_RUNNER_ENSEMBLE_PHONE_PLAYBACK=1`. Run one method per xcodebuild invocation
/// (`-only-testing`) so each has its own app session log, then pull the logs with
/// `devicectl` and check the journey lines named in each test's doc comment.
///
/// State comes from the DEBUG-only `automation.playback.probe` element and the
/// `ensemble://debug/play` and `debug/transport` links, never from pixels. Tests
/// never tap Add to…, Remove, Delete, rating or favourite controls and never touch
/// the Plex account. Streaming checks launch with
/// `-EnsembleAutomationForceNetworkStream YES`, which resolves playback as if no
/// track were downloaded or stream-cached; it changes no setting or download.
final class PhonePlaybackAcceptanceUITests: XCTestCase {
    // Plex rating keys on the SE's server (codecs confirmed against PMS metadata).
    enum Key {
        static let wav = "8731"          // Julie, Pt. II (Valice, Sugarjulie) PCM WAV, 3:02
        static let wavNext = "8732"      // Five Feet from the Floor, WAV, 3:02
        static let mp3 = "7278"          // Fly Free (3 Letters Back) MP3
        static let aac = "7631"          // Gimme That Swing! (Cissie Redgwick) AAC
        static let flac = "11741"        // Overture (AJR) FLAC, 2:38
        static let christmasInJune = "11631"  // truncated FLAC (known)
        static let noahsDescendants = "11700" // damaged (known)
        static let twentyOnePilots = ["14291", "14292", "14293"]
        // Downloaded Sugarjulie tracks: local-file queue for gapless and transport checks.
        static let local = ["8728", "8729", "8730", "8731", "8732", "8733"]
    }

    struct Probe {
        let state: String, id: String, pos: Double, dur: Double, idx: Int, count: Int, err: String, pid: Int, mix: Bool, net: String

        init?(_ value: String?) {
            guard let value else { return nil }
            var fields: [String: String] = [:]
            for part in value.split(separator: "|", omittingEmptySubsequences: false) {
                let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            guard let state = fields["state"] else { return nil }
            self.state = state
            id = fields["id"] ?? ""
            pos = Double(fields["pos"] ?? "") ?? 0
            dur = Double(fields["dur"] ?? "") ?? 0
            idx = Int(fields["idx"] ?? "") ?? 0
            count = Int(fields["count"] ?? "") ?? 0
            err = fields["err"] ?? ""
            pid = Int(fields["pid"] ?? "") ?? 0
            mix = fields["mix"] == "1"
            net = fields["net"] ?? ""
        }

        var text: String { "pid=\(pid) net=\(net) mix=\(mix) state=\(state) id=\(id) pos=\(pos) dur=\(dur) idx=\(idx)/\(count) err=\(err)" }
    }

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    let app = XCUIApplication()
    private(set) var timeline: [String] = []
    private var lastNoted = ""
    private var lastNotedAt = Date.distantPast
    private let started = Date()
    private var didLaunch = false
    private(set) var launchPid = 0
    /// Set while Airplane Mode is on, so tearDown always turns it back off.
    var airplaneIsOn = false
    var airplaneToggles = 0
    var wifiToggles = 0
    private(set) var relaunchesByLinks = 0

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENSEMBLE_PHONE_PLAYBACK"] == "1")
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone)
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        guard didLaunch else { return }
        if airplaneIsOn || airplaneToggles % 2 == 1 || wifiToggles % 2 == 1 { restoreNetwork() }
        if app.state == .runningForeground { transport("pause") }
        log("end app.state=\(app.state.rawValue)")
        let attachment = XCTAttachment(string: timeline.joined(separator: "\n"))
        attachment.name = "timeline"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Group 1: streaming by codec

    /// WAV streams to its natural end and advances. Default quality may transcode;
    /// the journey log's `sourceDecisionCompleted` names kind=directHTTP or transcodedHTTP.
    func testG1a_WAVStreamsToNaturalEnd_DefaultQuality() throws { try streamWAVToEnd(quality: nil) }

    /// Same at original quality, the direct PCM path of the d735bf26 fix.
    func testG1b_WAVStreamsToNaturalEnd_OriginalQuality() throws { try streamWAVToEnd(quality: "original") }

    /// One direct download per server: the first track's download is held incomplete (15 s chunk delay), so the
    /// successor's prefetch, which starts at first audio, would otherwise request its own file mid-download and
    /// make Plex end the first ("Client stopped playback", NSURLErrorDomain -1005). Pass: the first track plays
    /// and stays kind=directHTTP, the advance happens, and the session log has no "failed after startup".
    /// The Plex log check is done by the runner. `TEST_RUNNER_ENSEMBLE_SERIAL_TRACKS=a,b` picks other original-
    /// quality tracks when the library lacks the default WAV pair.
    func testG1g_SuccessorPrefetchWaitsForDirectDownload() throws {
        let keys = ProcessInfo.processInfo.environment["ENSEMBLE_SERIAL_TRACKS"]?.split(separator: ",").map(String.init)
            ?? [Key.wav, Key.wavNext]
        launch(quality: "original", forceStream: true, environment: [
            "ENSEMBLE_AUTOMATION_STREAM_DELAY_TRACK": keys[0],
            "ENSEMBLE_AUTOMATION_STREAM_DELAY_SECONDS": "15",
        ])
        play(keys)
        let first = wait(90, "first track playing") { $0.id == keys[0] && $0.state == "playing" && $0.pos >= 3 }
        XCTAssertNotNil(first, "First track did not start streaming")
        let advanced = wait(420, "advance to the successor") { $0.id == keys[1] && $0.state == "playing" }
        XCTAssertNotNil(advanced, "Playback did not advance after the first track's natural end")
        let later = wait(30, "successor progressing") { $0.id == keys[1] && $0.pos >= 3 }
        XCTAssertNotNil(later, "Successor did not progress")
        XCTAssertEqual(app.state, .runningForeground, "App left the foreground (crash?)")
    }

    func testG1c_MP3Streams20s() throws { try streamSeconds(Key.mp3, quality: nil) }
    func testG1d_AAC_Streams20s() throws { try streamSeconds(Key.aac, quality: nil) }
    func testG1e_FLACStreams20s_DefaultQuality() throws { try streamSeconds(Key.flac, quality: nil) }
    func testG1f_FLACStreams20s_OriginalQuality() throws { try streamSeconds(Key.flac, quality: "original") }

    private func streamWAVToEnd(quality: String?) throws {
        launch(quality: quality, forceStream: true)
        play([Key.wav, Key.wavNext])
        let first = wait(90, "WAV playing") { $0.id == Key.wav && $0.state == "playing" && $0.pos >= 3 }
        XCTAssertNotNil(first, "WAV did not start streaming")
        let advanced = wait(300, "advance to next WAV") { $0.id == Key.wavNext && $0.state == "playing" }
        XCTAssertNotNil(advanced, "WAV did not advance after its natural end")
        let later = wait(30, "next track progressing") { $0.id == Key.wavNext && $0.pos >= 3 }
        XCTAssertNotNil(later, "Successor did not progress")
        XCTAssertEqual(app.state, .runningForeground, "App left the foreground (crash?)")
    }

    private func streamSeconds(_ key: String, quality: String?) throws {
        launch(quality: quality, forceStream: true)
        play([key])
        let reached = wait(120, "20 s of \(key)") { $0.id == key && $0.state == "playing" && $0.pos >= 20 }
        XCTAssertNotNil(reached, "Track \(key) did not reach 20 s")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Group 2: damaged files (known)

    /// 11631 at a non-original quality: two quick retries, then skip or halt with an error;
    /// never a spin at 0:00. Successor 11741 is a healthy FLAC.
    func testG2a_ChristmasInJune_SkipsAfterRetries() throws {
        launch(quality: "high", forceStream: true)
        play([Key.christmasInJune, Key.flac])
        let settled = wait(120, "11631 settles") { $0.id != Key.christmasInJune || $0.state == "failed" }
        XCTAssertNotNil(settled, "11631 neither skipped nor halted within 120 s")
        _ = wait(25, "post-settle") { _ in false }
        let final = read()
        log("final \(final?.text ?? "nil")")
        XCTAssertFalse(final?.id == Key.christmasInJune && final?.state != "failed" && (final?.pos ?? 0) < 0.5,
                       "Spinning at 0:00 on 11631")
    }

    /// 11631 followed by the also-damaged 11700: skip once, then halt on the error.
    func testG2b_ChristmasInJune_ThenFailingSuccessorHalts() throws {
        launch(quality: "high", forceStream: true)
        play([Key.christmasInJune, Key.noahsDescendants])
        let halted = wait(150, "halt on error") { $0.state == "failed" }
        XCTAssertNotNil(halted, "Playback did not halt on the error after two failing tracks")
        let still = wait(20, "stays failed") { $0.state != "failed" }
        XCTAssertNil(still, "Playback left the failed state again")
    }

    /// 11700 alone: one failure with an error, no retry loop (count `engineLoadFailed` in the log).
    func testG2c_NoahsDescendants_FailsOnce() throws {
        launch(quality: nil, forceStream: true)
        play([Key.noahsDescendants])
        let failed = wait(60, "11700 fails") { $0.state == "failed" }
        XCTAssertNotNil(failed, "11700 did not report an error")
        let recovered = wait(30, "no loop") { $0.state != "failed" }
        XCTAssertNil(recovered, "11700 left the failed state (loop?)")
    }

    /// twenty one pilots self-titled at original quality: record what each track does, observed to its
    /// natural end (a corrupt frame is expected to show as retries then a skip or halt).
    func testG2d1_TwentyOnePilots_ImplicitDemandForProof() throws { try observeToEnd(Key.twentyOnePilots[0]) }
    func testG2d2_TwentyOnePilots_FallAway() throws { try observeToEnd(Key.twentyOnePilots[1]) }
    func testG2d3_TwentyOnePilots_ThePantaloon() throws { try observeToEnd(Key.twentyOnePilots[2]) }

    private func observeToEnd(_ key: String) throws {
        launch(quality: "original", forceStream: true)
        play([key])
        var outcome = "unsettled"
        var maxPos = 0.0
        var duration = 0.0
        var lastPos = 0.0
        var lastMove = Date()
        let limit = Date().addingTimeInterval(420)
        while Date() < limit {
            guard let p = read() else { continue }
            note(p)
            maxPos = max(maxPos, p.pos)
            duration = max(duration, p.dur)
            if p.pos > lastPos + 0.2 { lastPos = p.pos; lastMove = Date() }
            if p.state == "failed" { outcome = "failed at \(String(format: "%.1f", maxPos)) s of \(duration): \(p.err)"; break }
            if p.state == "paused" || p.state == "stopped" { outcome = "\(p.state) at maxPos \(String(format: "%.1f", maxPos)) of \(duration) (queue end)"; break }
            if p.state == "playing" && Date().timeIntervalSince(lastMove) > 20 { outcome = "STALLED playing at \(p.pos) for 20 s"; break }
            Thread.sleep(forTimeInterval: 1)
        }
        log("OUTCOME \(key): \(outcome)")
        attachText("outcome-\(key)", outcome)
        XCTAssertNotEqual(outcome, "unsettled", "\(key) neither ended nor failed within 420 s")
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Group 3: playback position and sweep fixes (downloaded tracks, shuffle and SmartMix off)

    /// Pause and resume after gapless advances: scrubber continues from the paused time.
    /// Log: `ITEM_CHANGED ... via gapless`, and no `Ignoring render clock`.
    func testG3a_PauseResumeAfterGaplessAdvances() throws {
        launch()
        play(Key.local)
        try advanceGaplessly(times: 3)
        try assertPauseResumeContinuity()
    }

    /// Relaunch and resume (62e82bac): paused mid-queue, force-quit, relaunch, play, gapless advance.
    /// Log: no `dropped native ... outside a session`.
    func testG3c_RelaunchResumeIntoGaplessAdvance() throws {
        launch()
        play(Key.local, index: 1)
        let playing = wait(60, "playing") { $0.state == "playing" && $0.pos >= 15 }
        let before = try XCTUnwrap(playing)
        transport("pause")
        XCTAssertNotNil(wait(10, "paused") { $0.state == "paused" })
        app.terminate()
        launch()
        let restored = wait(60, "restored queue") { $0.count == Key.local.count && $0.id == before.id }
        XCTAssertNotNil(restored, "Queue was not restored at the paused track")
        transport("resume")
        let resumed = wait(30, "resume plays") { $0.state == "playing" && $0.pos >= (restored?.pos ?? 0) }
        XCTAssertNotNil(resumed)
        let target = max((resumed?.dur ?? 0) - 8, 5)
        transport("seek", to: target)
        let advanced = wait(60, "gapless advance after relaunch") { $0.idx == before.idx + 1 && $0.state == "playing" }
        XCTAssertNotNil(advanced, "No advance after resume")
        let after = wait(15, "new track progressing") { $0.idx == before.idx + 1 && $0.pos >= 2 && $0.pos < 20 }
        XCTAssertNotNil(after, "Position does not follow the new track")
    }

    /// Sweep: paused Next, then Previous, then Play: the scrubber moves again.
    func testG3d_PausedNextPreviousPlay() throws {
        launch()
        play(Key.local, index: 1)
        XCTAssertNotNil(wait(60, "playing") { $0.state == "playing" && $0.pos >= 3 })
        transport("pause")
        XCTAssertNotNil(wait(10, "paused") { $0.state == "paused" })
        transport("next")
        XCTAssertNotNil(wait(20, "next while paused") { $0.idx == 2 && $0.state == "paused" && $0.pos < 1 },
                        "Paused Next did not land paused at 0:00")
        transport("previous")
        XCTAssertNotNil(wait(20, "previous while paused") { $0.idx == 1 && $0.state == "paused" && $0.pos < 1 },
                        "Paused Previous did not land paused at 0:00")
        transport("resume")
        let moving = wait(20, "play moves the scrubber") { $0.state == "playing" && $0.pos >= 3 }
        XCTAssertNotNil(moving, "Play after paused Next/Previous did not advance the position")
    }

    /// Sweep: relaunch, Next within 3 s, wait 5 s, Play: the new track starts at 0:00.
    func testG3e_RelaunchThenNextWithin3s() throws {
        launch()
        play(Key.local, index: 1)
        XCTAssertNotNil(wait(60, "playing") { $0.state == "playing" && $0.pos >= 10 })
        transport("pause")
        XCTAssertNotNil(wait(10, "paused") { $0.state == "paused" })
        app.terminate()
        launch()
        let t = Date()
        transport("next")
        log("Next sent \(String(format: "%.1f", Date().timeIntervalSince(t))) s after the probe appeared")
        XCTAssertNotNil(wait(20, "next lands") { $0.idx == 2 && $0.state == "paused" })
        Thread.sleep(forTimeInterval: 5)
        let beforePlay = read()
        XCTAssertEqual(beforePlay?.state, "paused", "Track started playing while paused")
        transport("resume")
        let started = wait(20, "plays from the start") { $0.idx == 2 && $0.state == "playing" && $0.pos > 0 }
        XCTAssertNotNil(started)
        XCTAssertLessThan(started?.pos ?? 99, 4, "New track did not start at 0:00")
    }

    /// Sweep: autoplay off while an autoplay track plays keeps the playing item; Next then ends the queue.
    func testG3f_AutoplayOffWhileAutoplayTrackPlays() throws {
        launch(autoplay: true)
        let last = Key.local[0]
        play([last])
        let playing = wait(60, "playing") { $0.state == "playing" && $0.pos >= 2 && $0.dur > 20 }
        transport("seek", to: (playing?.dur ?? 60) - 8)
        let auto = wait(90, "autoplay track plays") { $0.id != last && $0.state == "playing" && $0.pos >= 2 }
        let autoTrack = try XCTUnwrap(auto, "No autoplay track started")
        openLink("now-playing?autoplay=off")
        Thread.sleep(forTimeInterval: 4)
        let kept = read()
        log("after autoplay off: \(kept?.text ?? "nil")")
        XCTAssertEqual(kept?.id, autoTrack.id, "Autoplay off changed the playing track")
        XCTAssertEqual(kept?.state, "playing", "Autoplay off stopped the playing track")
        transport("next")
        Thread.sleep(forTimeInterval: 4)
        let afterNext = read()
        log("after Next: \(afterNext?.text ?? "nil")")
        attachText("autoplay-off-after-next", afterNext?.text ?? "nil")
        // Expected: the queue ends (paused on the last item) since no non-autoplay item follows.
        XCTAssertTrue(afterNext?.state == "paused" || afterNext?.id != autoTrack.id,
                      "Next after autoplay off neither ended the queue nor advanced")
    }

    // MARK: - Group 4: step 1b queue policy

    /// End of queue: natural end and Next on the last item leave it paused at 0:00, queue kept.
    func testG4a_EndOfQueueLeavesLastItemPaused() throws {
        launch()
        play(Array(Key.local[0...1]), index: 1)
        let playing = wait(60, "playing") { $0.state == "playing" && $0.pos >= 2 && $0.dur > 20 }
        transport("seek", to: (playing?.dur ?? 60) - 6)
        let ended = wait(40, "natural end pauses") { $0.state == "paused" && $0.pos < 1 }
        XCTAssertNotNil(ended, "Natural end did not leave the last item paused at 0:00")
        XCTAssertEqual(ended?.count, 2)
        XCTAssertEqual(ended?.idx, 1)
        transport("resume")
        XCTAssertNotNil(wait(20, "plays again") { $0.state == "playing" && $0.pos >= 2 })
        transport("next")
        let next = wait(20, "next on last") { $0.state == "paused" && $0.pos < 1 }
        XCTAssertNotNil(next, "Next on the last item did not leave it paused at 0:00")
        XCTAssertEqual(next?.idx, 1)
        XCTAssertEqual(next?.count, 2)
    }

    /// Next on the last item under Repeat One wraps to the first item.
    func testG4b_RepeatOneNextOnLastWraps() throws {
        launch()
        openLink("now-playing?repeat=one")
        defer { openLink("now-playing?repeat=off") }
        play(Array(Key.local[0...1]), index: 1)
        XCTAssertNotNil(wait(60, "playing last item") { $0.idx == 1 && $0.state == "playing" && $0.pos >= 2 })
        transport("next")
        let wrapped = wait(20, "wraps") { $0.idx == 0 && $0.state == "playing" }
        XCTAssertNotNil(wrapped, "Next on the last item under Repeat One did not wrap to the first")
    }

    // MARK: - Helpers for groups 3-5

    /// Seeks to eight seconds before the end and waits for the gapless advance, `times` times.
    func advanceGaplessly(times: Int) throws {
        for step in 1...times {
            let p = wait(60, "track \(step - 1) playing") { $0.idx == step - 1 && $0.state == "playing" && $0.pos >= 1 && $0.dur > 20 }
            transport("seek", to: (try XCTUnwrap(p, "Track \(step - 1) not playing")).dur - 8)
            XCTAssertNotNil(wait(60, "advance \(step)") { $0.idx == step && $0.state == "playing" }, "No advance \(step)")
        }
    }

    func assertPauseResumeContinuity() throws {
        let playing = try XCTUnwrap(wait(30, "playing after advances") { $0.state == "playing" && $0.pos >= 3 })
        transport("pause")
        let paused = try XCTUnwrap(wait(10, "paused") { $0.state == "paused" })
        Thread.sleep(forTimeInterval: 4)
        let still = try XCTUnwrap(read())
        XCTAssertEqual(still.state, "paused")
        XCTAssertEqual(still.pos, paused.pos, accuracy: 0.6, "Paused scrubber drifted")
        XCTAssertEqual(still.id, playing.id)
        transport("resume")
        let resumed = try XCTUnwrap(wait(15, "resumed") { $0.state == "playing" && $0.pos > paused.pos })
        XCTAssertLessThan(resumed.pos, paused.pos + 8, "Resume jumped away from the paused time")
        XCTAssertEqual(resumed.id, playing.id)
    }

    func attachText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Link delivery must not relaunch the app: pid is stable across play, pause and resume links.
    func testZ0_LinksDoNotRelaunchTheApp() throws {
        launch()
        play([Key.local[0]])
        XCTAssertNotNil(wait(60, "playing") { $0.state == "playing" && $0.pos >= 3 })
        transport("pause")
        XCTAssertNotNil(wait(10, "paused") { $0.state == "paused" })
        transport("resume")
        XCTAssertNotNil(wait(10, "resumed") { $0.state == "playing" })
        XCTAssertEqual(relaunchesByLinks, 0, "A debug link relaunched the app")
        XCTAssertNotEqual(launchPid, 0)
    }

    /// Discovery: labels on the Now Playing queue page (Autoplay, SmartMix, shuffle, repeat controls) and the mini player.
    func testZ2_DiscoverNowPlayingControls() throws {
        launch()
        play(Key.local)
        XCTAssertNotNil(wait(60, "playing") { $0.state == "playing" && $0.pos >= 2 })
        attachText("miniplayer-labels", appLabels().joined(separator: "\n"))
        openLink("now-playing?page=queue")
        XCTAssertTrue(app.buttons["Close Now Playing"].firstMatch.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1.5)
        attachText("queue-labels", appLabels().joined(separator: "\n"))
        openLink("now-playing?page=controls")
        Thread.sleep(forTimeInterval: 1.5)
        attachText("controls-labels", appLabels().joined(separator: "\n"))
    }

    func appLabels() -> [String] {
        app.descendants(matching: .any).allElementsBoundByIndex.prefix(120).compactMap { element -> String? in
            let label = element.label
            let value = (element.value as? String) ?? ""
            guard !label.isEmpty || !element.identifier.isEmpty else { return nil }
            return "\(element.elementType.rawValue):\(label)\(element.identifier.isEmpty ? "" : " #" + element.identifier)\(value.isEmpty ? "" : " =" + value)"
        }
    }

    // MARK: - Step 1e G7 (shuffle toggle) and step 2 launch surfaces

    /// G7 on Plex: toggling shuffle mid-track keeps the track playing; the next track comes from the new order.
    func testG4d_ShuffleToggleKeepsTrackPlaying() throws {
        launch()
        play(Key.local)
        let p = try XCTUnwrap(wait(60, "playing") { $0.state == "playing" && $0.pos >= 3 })
        defer { openLink("now-playing?shuffle=off") }
        openLink("now-playing?shuffle=on")
        Thread.sleep(forTimeInterval: 3)
        let kept = try XCTUnwrap(read())
        XCTAssertEqual(kept.id, p.id, "Shuffle changed the playing track")
        XCTAssertEqual(kept.state, "playing")
        XCTAssertGreaterThan(kept.pos, p.pos)
        transport("next")
        let next = wait(20, "next after shuffle") { $0.id != p.id && $0.state == "playing" }
        XCTAssertNotNil(next)
        attachText("shuffle-next", "before \(p.id) after \(next?.id ?? "nil") idx \(next?.idx ?? -1)")
    }

    /// Step 2c/2d: the Downloads sheet opens from its debug route and the app stays up.
    func testG5e_DownloadsSheetOpens() throws {
        launch()
        openLink("open?surface=downloads")
        let opened = app.navigationBars["Downloads"].firstMatch.waitForExistence(timeout: 20)
            || app.staticTexts["Downloads"].firstMatch.waitForExistence(timeout: 5)
        attach("downloads")
        attachText("downloads-labels", appLabels().joined(separator: "\n"))
        XCTAssertTrue(opened, "Downloads did not open")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Step 0 Control Center tile: the tile shows the item (one Springboard query), and Pause, Play and Next
    /// taps (by coordinate) change playback, verified through the app's probe.
    func testG5d_ControlCenterMediaTile() throws {
        launch()
        play(Key.local)
        let p = try XCTUnwrap(wait(60, "playing") { $0.state == "playing" && $0.pos >= 3 })
        openControlCenter()
        let tileShown = tilePosition.waitForExistence(timeout: 120)
        log("tile shown=\(tileShown) position=\(tileShown ? (tilePosition.value as? String ?? "?") : "-")")
        XCTAssertTrue(tileShown, "No media tile in Control Center")
        tapControlCenter(CC.tilePlayPause)
        XCTAssertNotNil(wait(10, "tile Pause pauses") { $0.state == "paused" }, "Control Center Pause did not pause")
        tapControlCenter(CC.tilePlayPause)
        XCTAssertNotNil(wait(10, "tile Play resumes") { $0.state == "playing" }, "Control Center Play did not resume")
        tapControlCenter(CC.tileNext)
        let next = wait(15, "tile Next advances") { $0.idx == p.idx + 1 && $0.state == "playing" }
        closeControlCenter()
        XCTAssertNotNil(next, "Control Center Next did not advance")
    }

    /// AirPlay: opens the route picker from Control Center's media tile and records the receivers it lists. It
    /// selects a receiver only when ENSEMBLE_PHONE_AIRPLAY_ROUTE names one (for example "Garage HomePod"), because
    /// that plays through someone's speaker; the default run just proves the picker can be driven.
    func testG3h_AirPlayRoutePickerOpensFromControlCenter() throws {
        launch()
        play(Key.local)
        XCTAssertNotNil(wait(60, "playing") { $0.state == "playing" && $0.pos >= 3 })
        openControlCenter()
        tapControlCenter(CGVector(dx: 0.49, dy: 0.495))    // the tile's AirPlay button
        Thread.sleep(forTimeInterval: 3)
        attach("airplay-route-picker")
        let receivers = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'HomePod' OR label CONTAINS[c] 'Home Theater' OR label CONTAINS[c] 'Apple TV'"))
            .allElementsBoundByIndex.prefix(20).map(\.label)
        log("AirPlay receivers listed: \(receivers)")
        attachText("airplay-receivers", receivers.joined(separator: "\n"))
        XCTAssertFalse(receivers.isEmpty, "The AirPlay route picker listed no receivers")
        if let route = ProcessInfo.processInfo.environment["ENSEMBLE_PHONE_AIRPLAY_ROUTE"], !route.isEmpty {
            springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", route)).firstMatch.tap()
            Thread.sleep(forTimeInterval: 5)
            log("selected \(route): \(read()?.text ?? "nil")")
        }
        closeControlCenter()
    }

    /// WAV direct stream with no successor to prefetch: isolates the direct PCM path from prefetch concurrency.
    /// Batch 3 saw the direct stream of 8731 lose its connection at 5 MiB while 8732's prefetch started.
    func testG1g_WAVOriginalQuality_SingleTrackNoPrefetch() throws {
        launch(quality: "original", forceStream: true)
        play([Key.wav])
        XCTAssertNotNil(wait(90, "WAV playing") { $0.id == Key.wav && $0.state == "playing" && $0.pos >= 3 })
        let ended = wait(300, "natural end of the only queue item") { $0.state == "paused" && $0.pos < 1 }
        XCTAssertNotNil(ended, "WAV did not reach its natural end")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Sweep: SmartMix cancel. During the first half of a crossfade, turn SmartMix off from the queue page:
    /// the outgoing track keeps playing to its end and then the queue advances.
    func testG3g_SmartMixCancelKeepsOutgoingTrack() throws {
        launch(smartMix: true)
        // SmartMix skips same-album transitions (batch 6), so use tracks from different albums.
        play([Key.mp3, Key.aac, Key.flac])
        let p = try XCTUnwrap(wait(90, "playing") { $0.state == "playing" && $0.pos >= 2 && $0.dur > 60 })
        openLink("now-playing?page=queue")
        XCTAssertTrue(app.buttons["Close Now Playing"].firstMatch.waitForExistence(timeout: 10))
        let smartMix = app.buttons["Smart Mix"].firstMatch
        XCTAssertTrue(smartMix.waitForExistence(timeout: 5))
        XCTAssertEqual(smartMix.value as? String, "On", "SmartMix did not start on for this run")
        transport("seek", to: p.dur - 30)
        let mixing = wait(60, "crossfade starts") { $0.mix }
        guard let mixing else {
            attachText("smartmix-no-crossfade", read()?.text ?? "nil")
            throw XCTSkip("No SmartMix crossfade started (planner fell back); cannot judge the cancel path")
        }
        smartMix.tap()
        let tapped = Date()
        let off = wait(10, "mix off") { !$0.mix }
        log("SmartMix turned off \(String(format: "%.1f", Date().timeIntervalSince(tapped))) s after the tap; mix began at pos \(mixing.pos) of \(mixing.dur)")
        XCTAssertNotNil(off, "Crossfade stayed active after SmartMix off")
        let still = try XCTUnwrap(read())
        XCTAssertEqual(still.id, mixing.id, "Cancelling the crossfade ended the outgoing track early")
        XCTAssertEqual(still.state, "playing")
        let advanced = wait(40, "advances after the outgoing track ends") { $0.idx == mixing.idx + 1 && $0.state == "playing" }
        XCTAssertNotNil(advanced, "Queue did not advance after the outgoing track ended")
    }

    /// Step 2c/2d: the Autoplay and SmartMix toggles on the queue page flip and restore.
    func testG5f_AutoplayAndSmartMixTogglesFlipAndRestore() throws {
        launch(forceModes: false)
        play([Key.local[0]])
        XCTAssertNotNil(wait(60, "playing") { $0.state == "playing" })
        openLink("now-playing?page=queue")
        XCTAssertTrue(app.buttons["Close Now Playing"].firstMatch.waitForExistence(timeout: 10))
        for name in ["Autoplay", "Smart Mix"] {
            let toggle = app.buttons[name].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "\(name) toggle missing")
            let original = toggle.value as? String ?? ""
            toggle.tap()
            XCTAssertTrue(waitFor(5, "\(name) flips") { (toggle.value as? String ?? "") != original }, "\(name) did not flip")
            toggle.tap()
            XCTAssertTrue(waitFor(5, "\(name) restores") { (toggle.value as? String ?? "") == original }, "\(name) did not restore")
        }
    }

    // MARK: - Auto-Lock (the lock button cannot be pressed from XCUITest on this phone)

    var settingsApp: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.Preferences") }
    /// Auto-Lock value found by testA0, restored by testZZ (same runner process).
    static var originalAutoLock: String?

    /// Sets Settings > Display & Brightness > Auto-Lock to `title`; returns the previous value ("Never", "1 Minute", ...).
    @discardableResult
    func setAutoLock(_ title: String) -> String? {
        let settings = settingsApp
        settings.launch()
        func find(_ label: String, prefix: Bool = false) -> XCUIElement {
            let format = prefix ? "label BEGINSWITH %@" : "label == %@"
            return settings.descendants(matching: .any).matching(NSPredicate(format: format, label)).firstMatch
        }
        let display = find("Display & Brightness")
        for _ in 0..<8 where !display.exists || !display.isHittable { settings.swipeUp() }
        guard display.exists else {
            attachText("settings-root", String(settings.debugDescription.prefix(30_000)))
            return nil
        }
        display.tap()
        let row = find("Auto-Lock", prefix: true)
        for _ in 0..<4 where !row.waitForExistence(timeout: 3) { settings.swipeUp() }
        guard row.exists else {
            attachText("settings-display", String(settings.debugDescription.prefix(30_000)))
            return nil
        }
        let description = "\(row.label) | \(row.value as? String ?? "")"
        let current = Self.autoLockTitle(from: description)
        log("Auto-Lock row: \(description) -> current '\(current)'")
        row.tap()
        let option = find(title)
        guard option.waitForExistence(timeout: 10) else {
            attachText("settings-autolock", String(settings.debugDescription.prefix(30_000)))
            return current
        }
        option.tap()
        Thread.sleep(forTimeInterval: 1)
        log("Auto-Lock set to \(title) (was \(current))")
        return current
    }

    /// "Auto-Lock, Never | " or "Auto-Lock | 30 Seconds" -> "Never" / "30 Seconds".
    static func autoLockTitle(from description: String) -> String {
        let parts = description.replacingOccurrences(of: "Auto-Lock", with: "")
            .components(separatedBy: CharacterSet(charactersIn: ",|"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.last ?? ""
    }

    /// Suite setup for the locked tests: Auto-Lock to 30 s so an idle phone truly locks (the lock button cannot be pressed).
    func testA0_SetAutoLockTo30Seconds() throws {
        launch()
        let previous = setAutoLock("30 Seconds")
        Self.originalAutoLock = previous
        attachText("auto-lock-original", previous ?? "UNKNOWN")
        log("original Auto-Lock: \(previous ?? "UNKNOWN")")
        XCTAssertNotNil(previous, "Could not drive Settings to Auto-Lock")
        app.activate()
    }

    /// Suite teardown: puts Auto-Lock back.
    func testZZ_RestoreAutoLock() throws {
        launch()
        let original = try XCTUnwrap(Self.originalAutoLock ?? ProcessInfo.processInfo.environment["ENSEMBLE_PHONE_ORIGINAL_AUTOLOCK"],
                                     "Original Auto-Lock unknown; set it by hand")
        setAutoLock(original)
        log("restored Auto-Lock to \(original)")
        app.activate()
    }

    /// Suite teardown: launch argument overrides for shuffle and autoplay were written back to the persisted
    /// settings (observed after batch 4); put them back to the phone's original On/On/repeat-off through the same
    /// calls as the queue-page buttons. Run last; the driver then diffs the preferences plist against its baseline.
    func testZZ9_RestoreShuffleAutoplayRepeat() throws {
        launch(forceModes: false)
        openLink("now-playing?shuffle=on&autoplay=on&repeat=off")
        Thread.sleep(forTimeInterval: 3)
        openLink("now-playing?page=queue")
        XCTAssertTrue(app.buttons["Close Now Playing"].firstMatch.waitForExistence(timeout: 15))
        for name in ["Shuffle", "Smart Mix", "Autoplay"] where app.buttons[name].firstMatch.value as? String != "On" {
            app.buttons[name].firstMatch.tap()      // the queue-page toggles are the same actions the links call
            Thread.sleep(forTimeInterval: 1)
        }
        let values = ["Shuffle", "Repeat", "Smart Mix", "Autoplay"].map { "\($0)=\(app.buttons[$0].firstMatch.value as? String ?? "?")" }
        log("queue page toggles: \(values.joined(separator: " "))")
        attachText("restored-toggles", values.joined(separator: "\n"))
        XCTAssertEqual(app.buttons["Shuffle"].firstMatch.value as? String, "On")
        XCTAssertEqual(app.buttons["Autoplay"].firstMatch.value as? String, "On")
        XCTAssertEqual(app.buttons["Smart Mix"].firstMatch.value as? String, "On")
        XCTAssertEqual(app.buttons["Repeat"].firstMatch.value as? String, "Off")
    }

    // MARK: - Locked-phone tests (judged by the journey log; Springboard queries are slow, so taps are by coordinate)

    /// Waits for the idle phone to lock (Auto-Lock 30 s), then wakes it to the Lock Screen with Home.
    func lockByIdle(idle: TimeInterval = 40, revealCoverSheet: Bool = false) {
        log("idle \(Int(idle)) s so Auto-Lock locks the phone")
        Thread.sleep(forTimeInterval: idle)
        XCUIDevice.shared.press(.home)       // wakes the phone; with no passcode it unlocks to the Home screen
        Thread.sleep(forTimeInterval: 2)
        log("woke: app.state=\(app.state.rawValue)")
        if revealCoverSheet {
            // The cover sheet (swipe down from the top) holds the same media controls the Lock Screen shows.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.002))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// Absolute Lock Screen frames of the media controls, read once (queries are slow), then used for taps.
    struct LockFrames { var play: CGRect; var next: CGRect; var previous: CGRect; var bar: CGRect }
    func readLockFrames() -> LockFrames? {
        let center = nowPlayingButton("CenterButton")
        guard center.waitForExistence(timeout: 180) else { return nil }
        let frames = LockFrames(play: center.frame, next: nowPlayingButton("RightButton").frame,
                                previous: nowPlayingButton("LeftButton").frame, bar: lockScreenPosition.frame)
        log("lock frames: play \(frames.play) next \(frames.next) bar \(frames.bar); label '\(center.label)'")
        return frames
    }

    func tap(_ rect: CGRect) {
        springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
        Thread.sleep(forTimeInterval: 1)
    }

    func unlockAndReturn() {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        _ = probeElement.waitForExistence(timeout: 30)
        log("returned: \(read()?.text ?? "no probe")")
    }

    /// G3b: pause and resume after a gapless advance with the phone locked. The advance, Pause and Play all
    /// happen on the locked phone; the log's STATE and NowPlaying elapsed lines show the scrubber continuity.
    func testG3b_PauseResumeAfterGaplessAdvance_Locked() throws {
        launch()
        play(Key.local)
        let p = try XCTUnwrap(wait(60, "playing") { $0.state == "playing" && $0.pos >= 2 && $0.dur > 90 })
        transport("seek", to: p.dur - 55)
        XCTAssertNotNil(wait(15, "seeked") { $0.pos >= p.dur - 56 })
        lockByIdle(idle: 70, revealCoverSheet: true)            // locks at ~30 s; the gapless advance lands at ~55 s
        let frames = try XCTUnwrap(readLockFrames(), "No Lock Screen media controls")
        tap(frames.play)                 // Pause
        let pausedAt = Date()
        Thread.sleep(forTimeInterval: 8)
        tap(frames.play)                 // Play
        let resumedAt = Date()
        Thread.sleep(forTimeInterval: 8)
        log("locked pause at \(Self.clock.string(from: pausedAt)), resume at \(Self.clock.string(from: resumedAt))")
        unlockAndReturn()
        let back = read()
        XCTAssertEqual(back?.idx, 1, "Queue did not advance while locked")
        XCTAssertEqual(back?.state, "playing", "Playback did not resume from the Lock Screen")
    }

    /// Step 0: Lock Screen play (Pause then Play) and scrub (drag the bar), position read back from the app.
    func testG5b_LockScreenPlayAndScrub() throws {
        launch()
        play(Key.local)
        let p = try XCTUnwrap(wait(60, "playing") { $0.state == "playing" && $0.pos >= 2 && $0.dur > 90 })
        lockByIdle(revealCoverSheet: true)
        let frames = try XCTUnwrap(readLockFrames(), "No Lock Screen media controls")
        tap(frames.play); Thread.sleep(forTimeInterval: 3); tap(frames.play)
        let start = CGVector(dx: frames.bar.minX + frames.bar.width * 0.05, dy: frames.bar.midY)
        let end = CGVector(dx: frames.bar.minX + frames.bar.width * 0.7, dy: frames.bar.midY)
        let origin = springboard.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(start).press(forDuration: 0.3, thenDragTo: origin.withOffset(end))
        Thread.sleep(forTimeInterval: 3)
        unlockAndReturn()
        let back = try XCTUnwrap(read())
        log("scrub result: \(back.text) (duration \(p.dur))")
        XCTAssertEqual(back.state, "playing")
        XCTAssertGreaterThan(back.pos, p.dur * 0.5, "Scrubbing the Lock Screen bar did not move the position")
    }

    /// Step 0: a natural track change while the phone is locked. Log: ITEM_CHANGED via gapless, no pause around it.
    func testG5a_BackgroundNaturalTrackChangeWhileLocked() throws {
        launch()
        play(Key.local)
        let p = try XCTUnwrap(wait(60, "playing") { $0.state == "playing" && $0.pos >= 2 && $0.dur > 90 })
        transport("seek", to: p.dur - 55)
        XCTAssertNotNil(wait(15, "seeked") { $0.pos >= p.dur - 56 })
        lockByIdle(idle: 70)
        unlockAndReturn()
        let back = read()
        XCTAssertEqual(back?.idx, 1, "Queue did not advance while locked")
        XCTAssertEqual(back?.state, "playing")
    }

    /// Step 1d (G11, G15): a failed track while locked skips once; a second failure halts with the error. The
    /// startup-stage injection is bypassed by a gapless advance (batch 7), so this uses the two real damaged
    /// files (11631 skips after its retries, 11700 halts), queued behind 8728 which ends while the phone is locked.
    func testG4c_FailedTrackWhileLockedSkipsOnceThenHalts() throws {
        launch(forceStream: true)
        play(["8728", Key.christmasInJune, Key.noahsDescendants, Key.flac])
        let p = try XCTUnwrap(wait(90, "first track playing") { $0.id == "8728" && $0.state == "playing" && $0.pos >= 3 })
        transport("seek", to: p.dur - 55)
        XCTAssertNotNil(wait(15, "seeked") { $0.pos >= p.dur - 56 })
        lockByIdle(idle: 70)
        unlockAndReturn()
        let halted = wait(60, "halted on error") { $0.state == "failed" }
        XCTAssertNotNil(halted, "Playback did not halt after the second failing track")
        XCTAssertEqual(halted?.idx, 2, "Expected the halt on the second failing track (index 2)")
    }

    /// Step 1d: Lock Screen state across a Next load; the NowPlaying lines in the log carry rate and state.
    func testG4e_LockScreenNextWhileLocked() throws {
        launch(forceStream: true)
        play(Array(Key.local[0...2]))
        XCTAssertNotNil(wait(90, "playing") { $0.state == "playing" && $0.pos >= 3 })
        lockByIdle(revealCoverSheet: true)
        let frames = try XCTUnwrap(readLockFrames(), "No Lock Screen media controls")
        tap(frames.next)                                   // Next while playing (load under playback)
        Thread.sleep(forTimeInterval: 6)
        tap(frames.play)                                   // Pause
        Thread.sleep(forTimeInterval: 2)
        tap(frames.next)                                   // Next while paused (load stays paused)
        Thread.sleep(forTimeInterval: 8)
        unlockAndReturn()
        let back = read()
        XCTAssertEqual(back?.state, "paused", "A track that loaded while paused is not paused")
        XCTAssertEqual(back?.idx, 2)
    }

    /// Step 1d: Pause from the Lock Screen right after Next, during the load, stays paused.
    func testG4f_LockScreenPauseDuringLoadStaysPaused() throws {
        launch(forceStream: true)
        play(Array(Key.local[0...2]))
        XCTAssertNotNil(wait(90, "playing") { $0.state == "playing" && $0.pos >= 3 })
        lockByIdle(revealCoverSheet: true)
        let frames = try XCTUnwrap(readLockFrames(), "No Lock Screen media controls")
        tap(frames.next)
        springboard.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frames.play.midX, dy: frames.play.midY)).tap()
        Thread.sleep(forTimeInterval: 10)
        unlockAndReturn()
        let back = read()
        XCTAssertEqual(back?.state, "paused", "Pause during a load did not stay paused")
    }

    // MARK: - Springboard (Lock Screen, Control Center)

    var springboard: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.springboard") }

    /// Locks the phone (private XCUIDevice selector, the usual XCUITest workaround) and waits for the app to background.
    func lockPhone() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        log("lock pressed")
        Thread.sleep(forTimeInterval: 2)
    }

    /// Wakes to the Lock Screen without unlocking (the SE has no passcode, but the lock button wakes to the Lock Screen).
    func wakeToLockScreen() {
        XCUIDevice.shared.perform(NSSelectorFromString("pressLockButton"))
        log("wake pressed")
        Thread.sleep(forTimeInterval: 2)
    }

    func unlockAndReactivate() {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)
        app.activate()
        log("unlocked, app.state=\(app.state.rawValue)")
        _ = probeElement.waitForExistence(timeout: 20)
    }

    /// The SE has a Home button: Control Center opens with a swipe up from the bottom edge.
    func openControlCenter() {
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        bottom.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        log("control center swipe up")
        Thread.sleep(forTimeInterval: 1.5)
    }

    func closeControlCenter() {
        for _ in 0..<2 where springboard.otherElements["airplane-button"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
            Thread.sleep(forTimeInterval: 1.2)
        }
        log("control center closed=\(!springboard.otherElements["airplane-button"].exists)")
    }

    /// Control Center's media tile (labels seen on iOS 27): buttons Previous/Pause or Play/Next, slider "Track position".
    func tileButton(_ label: String) -> XCUIElement { springboard.buttons[label].firstMatch }
    var tilePosition: XCUIElement { springboard.sliders["Track position"].firstMatch }

    /// Lock Screen / notification-cover media controls (identifiers seen on iOS 27 in batch 1).
    func nowPlayingButton(_ name: String) -> XCUIElement {
        springboard.buttons["UIA.MediaControls.NowPlaying.\(name)"].firstMatch   // CenterButton, LeftButton, RightButton
    }
    var lockScreenPosition: XCUIElement { springboard.otherElements["TrackPosition"].firstMatch }

    func springboardSummary() -> String {
        let center = nowPlayingButton("CenterButton")
        return "app.state=\(app.state.rawValue) coverSheet=\(springboard.windows["SBCoverSheetWindow"].exists) "
            + "media=\(center.exists) center='\(center.exists ? center.label : "")' "
            + "position='\(lockScreenPosition.exists ? ((lockScreenPosition.value as? String) ?? "") : "")'"
    }

    /// Discovery: does the lock button lock, does a second press wake to the Lock Screen with media controls,
    /// and where is Control Center. Summaries only (bounded queries), plus screenshots for the reviewer.
    func testZ1_DiscoverLockAndControlCenter() throws {
        launch()
        play(Key.local)
        XCTAssertNotNil(wait(60, "playing") { $0.state == "playing" && $0.pos >= 3 })
        log("before lock: \(springboardSummary())")
        lockPhone()
        log("after lock press: \(springboardSummary())")
        attach("after-lock-press")
        wakeToLockScreen()
        log("after wake press: \(springboardSummary())")
        attach("after-wake-press")
        if nowPlayingButton("CenterButton").exists {
            log("lock screen position before: \(lockScreenPosition.exists ? (lockScreenPosition.value as? String ?? "?") : "none")")
            nowPlayingButton("CenterButton").tap()
            Thread.sleep(forTimeInterval: 2)
            log("after lock-screen tap: \(springboardSummary())")
            nowPlayingButton("CenterButton").tap()
            Thread.sleep(forTimeInterval: 2)
            log("after second tap: \(springboardSummary())")
        }
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        log("after home: \(springboardSummary())")
        openControlCenter()
        attach("control-center")
        log("control center: airplane=\(springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Airplane'")).firstMatch.exists) "
            + "mediaCenter=\(nowPlayingButton("CenterButton").exists)")
        attachText("control-center-hierarchy", String(springboard.debugDescription.prefix(60_000)))
        closeControlCenter()
        app.activate()
        _ = probeElement.waitForExistence(timeout: 20)
        log("end: \(springboardSummary())")
    }


    /// Polls an arbitrary condition (Springboard state) every half second.
    func waitFor(_ timeout: TimeInterval, _ what: String, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { log("ok \(what)"); return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        log("TIMEOUT \(what)")
        return false
    }


    // MARK: - Airplane Mode (Control Center; the phone is on a cable, so the test runner stays connected)

    // Control Center layout on the SE (iOS 27), normalised from a 750x1334 screenshot. Springboard element
    // queries take ~100 s each here, so taps are by coordinate and verified through the probe's `net=` field.
    enum CC {
        static let airplane = CGVector(dx: 0.215, dy: 0.622)
        static let wifi = CGVector(dx: 0.215, dy: 0.712)
        static let tilePrevious = CGVector(dx: 0.36, dy: 0.375)
        static let tilePlayPause = CGVector(dx: 0.49, dy: 0.375)
        static let tileNext = CGVector(dx: 0.62, dy: 0.375)
    }

    /// Taps screen coordinates through the app's coordinate space: a tap through `springboard` first snapshots
    /// Springboard's whole hierarchy and took 60-120 s each (batch 5); the app's own snapshot is cheap.
    func tapControlCenter(_ point: CGVector) {
        app.coordinate(withNormalizedOffset: point).tap()
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Takes the network down (Airplane Mode, then Wi-Fi if iOS keeps Wi-Fi on in Airplane Mode) or restores it,
    /// verified by the app's own network state. Returns whether the app's state reached the wanted value.
    @discardableResult
    func setNetworkOffline(_ offline: Bool) -> Bool {
        let wanted: (Probe) -> Bool = { offline ? !$0.net.hasPrefix("online") : $0.net.hasPrefix("online") }
        openControlCenter()
        tapControlCenter(CC.airplane)
        closeControlCenter()
        airplaneToggles += 1
        if wait(25, "network \(offline ? "offline" : "online") after Airplane Mode", until: wanted) != nil {
            airplaneIsOn = offline
            return true
        }
        if offline {
            // iOS can keep Wi-Fi up in Airplane Mode; turn Wi-Fi off too.
            openControlCenter()
            tapControlCenter(CC.wifi)
            closeControlCenter()
            wifiToggles += 1
            if wait(25, "network offline after Wi-Fi off", until: wanted) != nil { airplaneIsOn = true; return true }
        }
        airplaneIsOn = offline
        return false
    }

    /// Restores whatever setNetworkOffline(true) changed: Wi-Fi first, then Airplane Mode.
    func restoreNetwork() {
        if wifiToggles % 2 == 1 { openControlCenter(); tapControlCenter(CC.wifi); closeControlCenter(); wifiToggles += 1 }
        if airplaneToggles % 2 == 1 { openControlCenter(); tapControlCenter(CC.airplane); closeControlCenter(); airplaneToggles += 1 }
        airplaneIsOn = false
        _ = wait(60, "network back online") { $0.net.hasPrefix("online") }
    }

    /// Stream drops mid-playback (network off, then on): playback recovers and keeps playing. The stream is held
    /// incomplete (20 s chunk delay, needs ENSEMBLE_AUTOMATION_MODE=1 in the environment) so the drop lands mid-transfer.
    func testG2e_NetworkDropMidStreamRecovers() throws {
        launch(quality: "original", forceStream: true, environment: [
            "ENSEMBLE_AUTOMATION_STREAM_DELAY_TRACK": Key.wav,
            "ENSEMBLE_AUTOMATION_STREAM_DELAY_SECONDS": "20",
        ])
        play([Key.wav])
        let p = try XCTUnwrap(wait(60, "streaming") { $0.id == Key.wav && $0.state == "playing" && $0.pos >= 2 })
        XCTAssertTrue(setNetworkOffline(true), "The app never saw the network go offline")
        Thread.sleep(forTimeInterval: 6)
        log("while offline: \(read()?.text ?? "nil")")
        restoreNetwork()
        let recovered = wait(120, "recovers and plays on") { $0.id == Key.wav && $0.state == "playing" && $0.pos >= p.pos + 12 }
        XCTAssertNotNil(recovered, "Playback did not recover after the network came back")
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// G18 (partly): pause an uncached stream, drop and restore the network, press Play: it continues from the
    /// same position. There is no SIM, so the Wi-Fi-to-cellular switch itself is not exercised.
    func testG4g_PausedStreamResumesAfterNetworkDrop() throws {
        launch(quality: "original", forceStream: true, environment: [
            "ENSEMBLE_AUTOMATION_STREAM_DELAY_TRACK": Key.wav,
            "ENSEMBLE_AUTOMATION_STREAM_DELAY_SECONDS": "20",
        ])
        play([Key.wav])
        _ = try XCTUnwrap(wait(60, "streaming") { $0.id == Key.wav && $0.state == "playing" && $0.pos >= 4 })
        transport("pause")
        let paused = try XCTUnwrap(wait(10, "paused") { $0.state == "paused" })
        XCTAssertTrue(setNetworkOffline(true), "The app never saw the network go offline")
        Thread.sleep(forTimeInterval: 6)
        restoreNetwork()
        Thread.sleep(forTimeInterval: 10)
        let t = Date()
        transport("resume")
        let resumed = wait(60, "resumes") { $0.state == "playing" && $0.pos > paused.pos }
        log("resume took \(String(format: "%.1f", Date().timeIntervalSince(t))) s: \(resumed?.text ?? "nil")")
        XCTAssertNotNil(resumed, "Play after the network drop did not continue")
        XCTAssertEqual(resumed?.pos ?? 0, paused.pos, accuracy: 15)
    }

    /// Step 0 offline playback: a downloaded track plays with the network down; a blocked (not downloaded) track
    /// reports an error instead of spinning.
    func testG5c_OfflineDownloadedTrackPlaysAndBlockedTrackErrors() throws {
        launch()
        XCTAssertTrue(setNetworkOffline(true), "The app never saw the network go offline")
        play([Key.local[2]])
        let local = wait(60, "downloaded track plays offline") { $0.state == "playing" && $0.pos >= 5 }
        XCTAssertNotNil(local, "Downloaded track did not play with the network down")
        launch(forceStream: true)
        log("relaunched offline: \(read()?.text ?? "nil")")
        play([Key.flac])
        let blocked = wait(30, "blocked track errors") { $0.state == "failed" }
        log("blocked offline track: \(blocked?.text ?? read()?.text ?? "nil")")
        attach("blocked-offline")
        attachText("blocked-offline-labels", appLabels().joined(separator: "\n"))
        XCTAssertNotNil(blocked, "A not-downloaded track did not report an error offline")
        restoreNetwork()
    }

    /// G17: a track already streamed in full plays with the network down. Downloads are ignored (stream cache kept)
    /// so the track is a stream-cache item, not a download. Log: `kind=cachedFile origin=streamCache`.
    func testG4h_G17_FullyStreamedTrackPlaysOffline() throws {
        launch(ignoreDownloads: true)
        play([Key.flac])
        XCTAssertNotNil(wait(120, "streams") { $0.id == Key.flac && $0.state == "playing" && $0.pos >= 30 })
        XCTAssertTrue(setNetworkOffline(true), "The app never saw the network go offline")
        play([Key.flac])
        let offline = wait(30, "plays from the stream cache offline") { $0.id == Key.flac && $0.state == "playing" && $0.pos >= 3 && $0.pos < 25 }
        XCTAssertNotNil(offline, "A fully streamed track did not play with the network down")
        restoreNetwork()
    }

    func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Driving the app

    /// Playback modes are forced per launch through argument-domain overrides (shuffle, SmartMix and
    /// autoplay off unless a test asks otherwise), so queue order is deterministic and the
    /// persisted settings stay as they are.
    func launch(quality: String? = nil, forceStream: Bool = false, ignoreDownloads: Bool = false, shuffle: Bool = false, smartMix: Bool = false,
                autoplay: Bool = false, forceModes: Bool = true, settle: TimeInterval = 6, environment: [String: String] = [:], extra: [String] = []) {
        var arguments = ["-EnsembleAutomationMode", "YES", "-EnsembleAutomationStartSurface", "playlists"]
        if forceModes {
            arguments += ["-isShuffleEnabled", shuffle ? "YES" : "NO",
                          "-isSmartMixEnabled", smartMix ? "YES" : "NO",
                          "-isAutoplayEnabled", autoplay ? "YES" : "NO"]
        }
        if forceStream { arguments += ["-EnsembleAutomationForceNetworkStream", "YES"] }
        if ignoreDownloads { arguments += ["-EnsembleAutomationIgnoreDownloads", "YES"] }
        // Argument-domain values override UserDefaults for this process only and are not persisted.
        if let quality { arguments += ["-streamingQuality", quality] }
        app.launchArguments = arguments + extra
        // The failure and stream-delay injections read ENSEMBLE_AUTOMATION_MODE from the environment, not the argument.
        app.launchEnvironment = environment.merging(["ENSEMBLE_AUTOMATION_MODE": "1"]) { $1 }
        app.launch()
        didLaunch = true
        log("launched args=\(app.launchArguments.joined(separator: " "))")
        XCTAssertTrue(probeElement.waitForExistence(timeout: 60), "Automation playback probe did not appear")
        // A play issued within ~100 ms of a cold launch races the Plex connection check and fails with
        // "Server is unavailable" (seen in batch 1); let the connection settle first.
        Thread.sleep(forTimeInterval: settle)
        launchPid = read()?.pid ?? 0
        log("launch pid \(launchPid)")
    }

    var probeElement: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "automation.playback.probe").firstMatch
    }

    func read() -> Probe? {
        guard probeElement.exists else { return nil }
        return Probe(probeElement.value as? String)
    }

    /// Delivers a debug link without relaunching the app. `XCUIApplication.open(_:)` kills and relaunches the
    /// process for every link (seen in batch 2: one new session log per link), which would reset playback
    /// state, so links go through the system handler instead. The probe's pid proves no relaunch happened.
    func openLink(_ route: String) {
        XCUIDevice.shared.system.open(URL(string: "ensemble://debug/\(route)")!)
        log("link \(route)")
        Thread.sleep(forTimeInterval: 1)
        if let p = read(), launchPid != 0, p.pid != launchPid {
            log("PROCESS CHANGED by link: pid \(launchPid) -> \(p.pid)")
            launchPid = p.pid
            relaunchesByLinks += 1
        }
    }

    /// Starts a queue. If the app reports "Server is unavailable" in the first seconds (cold-start connection race,
    /// not the behaviour under test), the request is logged and re-sent once the connection has settled.
    func play(_ keys: [String], index: Int = 0) {
        for attempt in 1...3 {
            openLink("play?tracks=\(keys.joined(separator: ","))&index=\(index)")
            let deadline = Date().addingTimeInterval(4)
            var unavailable = false
            while Date() < deadline {
                if let p = read(), p.state == "failed", p.err.contains("unavailable") { unavailable = true; break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard unavailable else { return }
            log("COLD-START server unavailable (attempt \(attempt)); retrying after 8 s")
            Thread.sleep(forTimeInterval: 8)
        }
    }

    func transport(_ action: String, to seconds: Double? = nil) {
        openLink("transport?action=\(action)" + (seconds.map { "&to=\($0)" } ?? ""))
    }

    /// Polls the probe every half second; records state changes and a sample every 5 s.
    @discardableResult
    func wait(_ timeout: TimeInterval, _ what: String, until condition: (Probe) -> Bool) -> Probe? {
        log("wait \(what) (\(Int(timeout)) s)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let p = read() {
                note(p)
                if condition(p) { log("ok \(what): \(p.text)"); return p }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        log("TIMEOUT \(what): \(read()?.text ?? "no probe")")
        return nil
    }

    private func note(_ p: Probe) {
        let key = "\(p.state)|\(p.id)|\(p.err)"
        if key != lastNoted || Date().timeIntervalSince(lastNotedAt) >= 5 {
            log("probe \(p.text)")
            lastNoted = key
            lastNotedAt = Date()
        }
    }

    func log(_ message: String) {
        let wall = Self.clock.string(from: Date())
        let line = String(format: "[%7.1f %@] %@", Date().timeIntervalSince(started), wall, message)
        timeline.append(line)
    }
}

// MARK: - Step 3c: Apple Music library on the shared writer

/// Drives the system Music and Settings apps beside Ensemble. Reads text only; never types into a
/// sign-in, passcode or payment prompt and never accepts a subscription offer.
extension PhonePlaybackAcceptanceUITests {
    func labels(of application: XCUIApplication, limit: Int = 200) -> String {
        application.descendants(matching: .any).allElementsBoundByIndex.prefix(limit).compactMap { element -> String? in
            let label = element.label
            let value = (element.value as? String) ?? ""
            guard !label.isEmpty || !value.isEmpty else { return nil }
            return "\(element.elementType.rawValue):\(label)\(value.isEmpty ? "" : " =" + value)"
        }.joined(separator: "\n")
    }

    /// Opens Music once, taps only plain Continue / Not Now notices, and dumps what is on screen.
    func testM0_MusicAppPreconditions() throws {
        let music = XCUIApplication(bundleIdentifier: "com.apple.Music")
        music.launch()
        for round in 1...4 {
            Thread.sleep(forTimeInterval: 4)
            attachText("music-labels-\(round)", labels(of: music))
            let plain = ["Continue", "Not Now", "Done"].map { music.buttons[$0] }.first { $0.exists && $0.isHittable }
            guard let button = plain else { break }
            let text = labels(of: music)
            // Subscription offers and sign-in prompts are never accepted.
            if text.localizedCaseInsensitiveContains("trial") || text.localizedCaseInsensitiveContains("password")
                || text.localizedCaseInsensitiveContains("Sign In") { attachText("music-stopped", text); break }
            button.tap()
        }
        for tab in ["Library", "Search", "Home", "Listen Now"] where music.tabBars.buttons[tab].exists {
            music.tabBars.buttons[tab].tap()
            Thread.sleep(forTimeInterval: 3)
            attachText("music-tab-\(tab)", labels(of: music))
        }
    }
}

extension PhonePlaybackAcceptanceUITests {
    /// Opens Music's Library tab and each library category, dumping text (no taps beyond navigation).
    func testM1_MusicLibraryContents() throws {
        let music = XCUIApplication(bundleIdentifier: "com.apple.Music")
        music.launch()
        Thread.sleep(forTimeInterval: 4)
        let library = music.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        Thread.sleep(forTimeInterval: 4)
        attachText("music-library-root", labels(of: music))
        for category in ["Songs", "Albums", "Artists", "Playlists"] {
            let row = music.buttons[category].firstMatch
            guard row.exists else { continue }
            row.tap()
            Thread.sleep(forTimeInterval: 4)
            attachText("music-library-\(category)", labels(of: music))
            music.swipeUp(velocity: .fast); music.swipeUp(velocity: .fast); music.swipeUp(velocity: .fast)
            Thread.sleep(forTimeInterval: 2)
            attachText("music-library-\(category)-end", labels(of: music, limit: 80))
            music.navigationBars.buttons.firstMatch.tap()
            Thread.sleep(forTimeInterval: 2)
        }
    }
}

extension PhonePlaybackAcceptanceUITests {
    /// Cold-launches Ensemble onto an automation surface (no playback probe is awaited).
    func launchEnsemble(surface: String, settle: TimeInterval = 8) {
        app.launchArguments = ["-EnsembleAutomationMode", "YES", "-EnsembleAutomationStartSurface", surface]
        app.launchEnvironment = ["ENSEMBLE_AUTOMATION_MODE": "1"]
        app.launch()
        Thread.sleep(forTimeInterval: settle)
    }

    /// Taps `Allow` / `OK` on a system permission alert if one is up; returns its text. Never taps anything else.
    @discardableResult
    func allowSystemAlert(timeout: TimeInterval = 12) -> String? {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return nil }
        let text = labels(of: springboard, limit: 40)
        attachText("system-alert", text)
        for title in ["Allow", "OK"] where alert.buttons[title].exists { alert.buttons[title].tap(); break }
        return text
    }

    /// Enables the Apple Music source from the Add Source screen and waits for the first sync to settle.
    func testM2_EnableAppleMusicSource() throws {
        launchEnsemble(surface: "add-source")
        attachText("add-source-before", appLabels().joined(separator: "\n"))
        let row = app.buttons["Apple Music"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "No Apple Music row on Add Source")
        row.tap()
        let alertText = allowSystemAlert()
        attachText("alert-seen", alertText ?? "no system alert")
        for round in 1...6 {
            Thread.sleep(forTimeInterval: 10)
            attachText("after-enable-\(round)", appLabels().joined(separator: "\n"))
        }
    }
}

extension PhonePlaybackAcceptanceUITests {
    var preferences: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.Preferences") }

    /// Scrolls the current Settings list until `label` is hittable, then taps it. Returns false when it never appears.
    @discardableResult
    func tapSettingsRow(_ label: String, in settings: XCUIApplication) -> Bool {
        let cell = settings.cells.containing(.staticText, identifier: label).firstMatch
        let row = cell.exists ? cell : settings.staticTexts[label].firstMatch
        for _ in 0..<12 {
            if row.exists, row.isHittable { row.tap(); Thread.sleep(forTimeInterval: 2); return true }
            settings.swipeUp(velocity: .default)
            Thread.sleep(forTimeInterval: 0.6)
        }
        return false
    }

    /// Opens Settings > Privacy & Security > Media & Apple Music and dumps it (discovery only).
    func testM3_DiscoverMediaPermissionPane() throws {
        let settings = preferences
        settings.launch()
        Thread.sleep(forTimeInterval: 3)
        // Start from the Settings root even if the app resumed deep in a pane.
        for _ in 0..<4 where settings.navigationBars.buttons.firstMatch.exists && settings.navigationBars.buttons.firstMatch.isHittable
            && settings.navigationBars.element.identifier != "com.apple.settings.root" {
            if settings.navigationBars.buttons.count > 0, settings.navigationBars.buttons.firstMatch.label != "" { settings.navigationBars.buttons.firstMatch.tap(); Thread.sleep(forTimeInterval: 1) } else { break }
        }
        attachText("settings-root", labels(of: settings, limit: 60))
        XCTAssertTrue(tapSettingsRow("Privacy & Security", in: settings), "no Privacy & Security row")
        attachText("privacy-pane", labels(of: settings, limit: 80))
        XCTAssertTrue(tapSettingsRow("Media & Apple Music", in: settings), "no Media & Apple Music row")
        attachText("media-pane", labels(of: settings, limit: 60))
    }
}

extension PhonePlaybackAcceptanceUITests {
    /// Sets Ensemble's Media & Apple Music switch in iOS Settings; returns the value read back ("1" on, "0" off).
    @discardableResult
    func setMediaPermission(_ on: Bool) -> String? {
        let settings = preferences
        settings.terminate()
        settings.launch()
        Thread.sleep(forTimeInterval: 3)
        var toggle = settings.switches["Ensemble"].firstMatch
        if !toggle.exists {
            if !settings.staticTexts["Media & Apple Music"].exists {
                tapSettingsRow("Privacy & Security", in: settings)
            }
            tapSettingsRow("Media & Apple Music", in: settings)
            toggle = settings.switches["Ensemble"].firstMatch
        }
        guard toggle.waitForExistence(timeout: 10) else { attachText("permission-switch-missing", labels(of: settings, limit: 60)); return nil }
        // The row is a switch containing a label button and the real switch; tap the trailing edge, where the control is.
        if (toggle.value as? String == "1") != on {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 2)
        }
        let value = toggle.value as? String
        attachText("permission-\(on ? "on" : "off")", "switch value after: \(value ?? "nil")")
        return value
    }

    /// Check 7: revoke Media & Apple Music mid-use, run a full sync, then restore the permission.
    func testM5_RevokeAccessThenSync() throws {
        launchEnsemble(surface: "profile", settle: 10)
        attachText("profile-before", appLabels().joined(separator: "\n"))
        XCTAssertEqual(setMediaPermission(false), "0", "could not revoke the permission")
        // Ensemble may have been terminated by the permission change; this launch is the "mid-use" resume.
        launchEnsemble(surface: "profile", settle: 10)
        openLink("sync?mode=full")
        Thread.sleep(forTimeInterval: 40)
        attachText("profile-after-revoked-sync", appLabels().joined(separator: "\n"))
        XCTAssertEqual(setMediaPermission(true), "1", "could not restore the permission")
        launchEnsemble(surface: "profile", settle: 10)
        openLink("sync?mode=full")
        Thread.sleep(forTimeInterval: 40)
        attachText("profile-after-restored-sync", appLabels().joined(separator: "\n"))
    }
}

extension PhonePlaybackAcceptanceUITests {
    /// Check 6, first half: Profile > Music Sources > Apple Music > Remove Source, confirming the alert.
    /// Removes only Ensemble's Apple Music source and its local rows; Plex is untouched.
    func testM4a_RemoveAppleMusicSource() throws {
        launchEnsemble(surface: "profile", settle: 10)
        let row = app.cells.containing(.staticText, identifier: "Apple Music").firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .default); Thread.sleep(forTimeInterval: 0.6) }
        XCTAssertTrue(row.exists, "No Apple Music row in Music Sources")
        row.tap()
        Thread.sleep(forTimeInterval: 2)
        attachText("apple-detail", labels(of: app, limit: 300))
        let remove = app.buttons["Remove Source"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        let confirm = app.alerts.firstMatch.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "No Remove confirmation")
        confirm.tap()
        Thread.sleep(forTimeInterval: 12)
        attachText("after-remove", labels(of: app, limit: 300))
    }
}

extension PhonePlaybackAcceptanceUITests {
    /// Check 2 probe: with Sync Library off, can Music add one catalog song to the library? Taps one Add control
    /// at most, and never `Turn On`, `Try`, `Subscribe` or a sign-in control.
    func testM6_TryAddOneSongWithSyncLibraryOff() throws {
        let music = XCUIApplication(bundleIdentifier: "com.apple.Music")
        music.launch()
        Thread.sleep(forTimeInterval: 4)
        music.tabBars.buttons["Search"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        let field = music.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Never Gonna Give You Up\n")
        Thread.sleep(forTimeInterval: 6)
        attachText("music-search-results", labels(of: music, limit: 400))
        let add = music.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add' AND NOT (label CONTAINS 'Playlist')")).firstMatch
        guard add.exists else { attachText("no-add-control", labels(of: music, limit: 120)); return }
        add.tap()
        Thread.sleep(forTimeInterval: 4)
        let after = labels(of: music, limit: 120)
        attachText("music-after-add", after)
        for dismiss in ["Cancel", "Not Now", "Close"] where music.buttons[dismiss].exists { music.buttons[dismiss].tap(); break }
    }
}

extension PhonePlaybackAcceptanceUITests {
    /// Opens Settings > Apps > Music and dumps it. Discovery only.
    func testM7_DiscoverMusicSettings() throws {
        let settings = preferences
        settings.terminate()
        settings.launch()
        Thread.sleep(forTimeInterval: 3)
        attachText("root", labels(of: settings, limit: 60))
        let found = tapSettingsRow("Apps", in: settings)
        attachText("apps-pane", labels(of: settings, limit: 400))
        XCTAssertTrue(found, "no Apps row")
        XCTAssertTrue(tapSettingsRow("Music", in: settings), "no Music row")
        attachText("music-pane", labels(of: settings, limit: 120))
    }
}

extension PhonePlaybackAcceptanceUITests {
    /// Opens Settings > Apps > Music and returns the Sync Library switch.
    func musicSyncLibrarySwitch(_ settings: XCUIApplication) -> XCUIElement {
        settings.terminate()
        settings.launch()
        Thread.sleep(forTimeInterval: 3)
        if !settings.staticTexts["Allow Music to Access"].exists {
            tapSettingsRow("Apps", in: settings)
            tapSettingsRow("Music", in: settings)
        }
        return settings.switches["Sync Library"].firstMatch
    }

    func promptText(_ settings: XCUIApplication) -> String {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        return "settings alerts: \(settings.alerts.count) sheets: \(settings.sheets.count)\n" + labels(of: settings, limit: 80)
            + "\n--- springboard alerts: \(springboard.alerts.count)\n" + labels(of: springboard, limit: 40)
    }

    /// Turns Sync Library on, taps nothing but the switch, and records any prompt text without answering it.
    func testM8_TurnOnSyncLibrary() throws {
        let settings = preferences
        let toggle = musicSyncLibrarySwitch(settings)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no Sync Library switch")
        attachText("sync-before", "value=\(toggle.value as? String ?? "nil")")
        guard toggle.value as? String == "0" else { return }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        for second in [2, 4, 8] {
            Thread.sleep(forTimeInterval: Double(second))
            attachText("sync-after-\(second)s", "value=\(toggle.value as? String ?? "nil")\n" + promptText(settings))
        }
    }
}

extension PhonePlaybackAcceptanceUITests {
    /// Reads Music's Library > Songs footer ("N songs"), swiping to the end of the list; nil if not reached.
    func musicSongCountFooter(_ music: XCUIApplication, maxSwipes: Int = 60) -> String? {
        let footer = music.staticTexts.matching(NSPredicate(format: "label MATCHES '.*[0-9,]+ Songs?.*'")).firstMatch
        for _ in 0..<maxSwipes {
            if footer.exists { return footer.label }
            music.swipeUp(velocity: .fast)
        }
        return footer.exists ? footer.label : nil
    }

    /// Watches Music's Library while the cloud library arrives; dumps top-of-screen text each round.
    func testM9_WatchLibraryArrive() throws {
        let music = XCUIApplication(bundleIdentifier: "com.apple.Music")
        music.launch()
        Thread.sleep(forTimeInterval: 4)
        music.tabBars.buttons["Library"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 3)
        attachText("library-root-0", labels(of: music, limit: 120))
        music.buttons["Songs"].firstMatch.tap()
        for round in 1...8 {
            Thread.sleep(forTimeInterval: 45)
            attachText("songs-round-\(round)", labels(of: music, limit: 40))
        }
        attachText("songs-footer", musicSongCountFooter(music) ?? "footer not reached")
    }
}

extension PhonePlaybackAcceptanceUITests {
    /// Runs `rounds` full syncs through the production coordinator, `gap` seconds apart; the session log carries the counts.
    func fullSyncRounds(_ rounds: Int, gap: TimeInterval = 100) {
        launchEnsemble(surface: "profile", settle: 8)
        for round in 1...rounds {
            openLink("sync?mode=full")
            Thread.sleep(forTimeInterval: gap)
            attachText("sync-round-\(round)", "done \(Self.clock.string(from: Date()))")
        }
    }

    func testM10_FullSyncSettle() throws { fullSyncRounds(4) }
}

extension PhonePlaybackAcceptanceUITests {
    /// The row's trailing "More" button: the one whose vertical centre matches `row`.
    func moreButton(beside row: XCUIElement, in app: XCUIApplication) -> XCUIElement? {
        let target = row.frame.midY
        return app.buttons.matching(identifier: "More").allElementsBoundByIndex
            .first { abs($0.frame.midY - target) < 30 && $0.frame.minX > row.frame.midX }
    }

    /// Adds the one allowed song to the library from catalog search (menu "Add to Library"; never Download or Play).
    func testM11_AddOneSongToLibrary() throws {
        let music = XCUIApplication(bundleIdentifier: "com.apple.Music")
        music.launch()
        Thread.sleep(forTimeInterval: 4)
        music.tabBars.buttons["Search"].firstMatch.tap()
        let field = music.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Never Gonna Give You Up\n")
        Thread.sleep(forTimeInterval: 6)
        attachText("search-results", labels(of: music, limit: 200))
        let row = music.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Never Gonna Give You Up, Song' AND label ENDSWITH 'Rick Astley'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "song row missing")
        let more = try XCTUnwrap(moreButton(beside: row, in: music), "no More button beside the row")
        more.tap()
        Thread.sleep(forTimeInterval: 2)
        attachText("song-menu", labels(of: music, limit: 120))
        let add = music.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "no Add item in the song menu")
        add.tap()
        Thread.sleep(forTimeInterval: 6)
        attachText("after-add", labels(of: music, limit: 120))
    }
}

extension PhonePlaybackAcceptanceUITests {
    /// Removes the one song testM11 added, from Library > Songs (menu "Delete from Library", then its confirmation).
    func testM13_RemoveTheAddedSong() throws {
        let music = XCUIApplication(bundleIdentifier: "com.apple.Music")
        music.launch()
        Thread.sleep(forTimeInterval: 4)
        music.tabBars.buttons["Library"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 2)
        music.buttons["Songs"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 4)
        attachText("songs-before-delete", labels(of: music, limit: 100))
        let row = music.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Never Gonna Give You Up'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "added song not listed in Songs")
        let more = try XCTUnwrap(moreButton(beside: row, in: music), "no More beside the song")
        more.tap()
        Thread.sleep(forTimeInterval: 2)
        attachText("song-menu", labels(of: music, limit: 120))
        let delete = music.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete from Library' OR label BEGINSWITH 'Remove from Library'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "no delete item")
        delete.tap()
        Thread.sleep(forTimeInterval: 2)
        attachText("delete-confirmation", labels(of: music, limit: 400))
        // The confirmation popup repeats the item label; its button is the last "Delete from Library".
        let confirms = music.buttons.matching(identifier: "Delete from Library").allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(confirms.count, 2, "no confirmation button")
        confirms.last?.tap()
        Thread.sleep(forTimeInterval: 6)
        attachText("songs-after-delete", labels(of: music, limit: 100))
    }
}
