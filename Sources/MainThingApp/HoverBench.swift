import AppKit
import MainThingCore
import SwiftUI

/// `MainThing --bench-hover [seconds]`: a fast up and down sweep over the open rows, without the
/// real cursor, and the main thread time it costs.
///
/// The real notch view and the real hover rules run in the bench's own panel: invisible (alpha 0),
/// click through, in the bottom left corner of the main screen. Synthesized mouse moves go straight
/// into the hosting view, and to `HoverController.evaluate` twice per move, as the tracking area and
/// the local monitor do in the app. No CGEvent is posted and the cursor never moves. A counter
/// stands in for the haptic performer, so no real trackpad ticks. The list is in memory: no tasks
/// file is read or written. `MAIN_THING_BENCH_DELAY=<seconds>` waits before the sweep, for
/// attaching Instruments (`scripts/bench-trace.sh`).
///
/// `MainThing --bench-hover [seconds] closed`: the notch stays collapsed and the cursor moves beside
/// it, as anywhere on screen. Only the global monitor's `evaluate` runs, once per move.
///
/// `MainThing --bench-hover gap [notch|menubar|menubar24]`: no timing. Steps the cursor down 1pt at
/// a time from the band's center to the add card, at the pills' center and 1pt inside their ends,
/// and at each height renders the hosting view and reads which pills are drawn filled. Exits 5
/// when some height has no filled pill (a dead zone) or two, or when the drawn one is not the
/// hover state. The fixtures are a 14 inch MacBook Pro (a hardware notch, the band hangs below the
/// menu bar), a Studio Display (no notch, the band is the 30pt menu bar row) and a 24pt menu bar;
/// without one the probe uses the main screen's own geometry.
@MainActor
enum HoverBench {
    static let fixtures: [String: ScreenInfo] = [
        "notch": ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32,
            auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
            auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32)
        ),
        "menubar": ScreenInfo(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410)),
        "menubar24": ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876)),
    ]

    static func run(seconds: Double, closed: Bool = false, gap: Bool = false, fixture: String? = nil) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else {
            print("bench: no screen")
            exit(1)
        }
        let environment = ProcessInfo.processInfo.environment
        let delay = Env.value("BENCH_DELAY", in: environment).flatMap(Double.init) ?? 1
        let geometry = NotchGeometry(screen: fixture.flatMap { fixtures[$0] } ?? ScreenInfo(screen))
        let store = TaskStore(previewTitles: [
            "Ship the launch post", "Reply to the design review", "Update the changelog",
            "Book the offsite room", "Draft the Q4 plan", "Send the invoices",
            "Review the hiring plan", "Write the weekly update",
        ])
        let model = NotchModel(geometry: geometry, apiPort: APIPort.preferred)
        // The probe reads the drawn state at once, without the hover fade.
        model.hoverAnimates = !gap
        let haptics = CountingPerformer()
        model.performer = haptics
        model.isOpen = !closed
        let rows = store.list.rows
        model.openWidth = PanelLayout.openWidth(rows: rows, geometry: geometry)
        let height = geometry.notchHeight + OpenLayout.contentHeight(rows: rows.count - 1) + OpenLayout.bounceHeadroom
        let size = CGSize(width: NotchGeometry.panelSize.width, height: max(ceil(height), NotchGeometry.panelSize.height))
        let frame = CGRect(origin: screen.frame.origin, size: size)

        let panel = NotchPanel(contentRect: frame)
        panel.alphaValue = 0
        let hosting = NotchHostingView(rootView: NotchView(store: store, model: model))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        // The hover rules flip click through on the panel they are given. That is a stand in with
        // the same frame that is never shown, so the invisible panel never takes a click.
        let standIn = NotchPanel(contentRect: frame)
        let silent = FileManager.default.temporaryDirectory.appendingPathComponent("main-thing-bench-\(getpid())")
        let hover = HoverController(
            panel: standIn, model: model, store: store,
            layout: PanelLayout(panel: standIn, model: model, store: store), sounds: Sounds(configDirectory: silent)
        )
        let card = CardController(model: model, store: store, panel: panel, toggle: { row in hover.toggleCompletion(of: row) })
        hover.card = card

        // Row centers from the top of the panel: the band, then rows 2..N.
        var centers = [geometry.notchHeight / 2]
        for index in 0..<(rows.count - 1) {
            centers.append(geometry.notchHeight + Lanes.topGap + Lanes.rowHeight * (CGFloat(index) + 0.5))
        }
        let top = centers.first!, bottom = centers.last!
        let x = size.width / 2
        let step = Lanes.rowHeight / 3

        Task { @MainActor in
            // Let the open layout and the row insertions settle first.
            try? await Task.sleep(for: .seconds(delay))
            // SwiftUI takes hover moves only after its tracking area saw the cursor come in.
            for area in hosting.trackingAreas where area.owner === hosting && !closed {
                if let enter = NSEvent.enterExitEvent(
                    with: .mouseEntered, location: CGPoint(x: x, y: size.height - top), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil
                ) {
                    hosting.mouseEntered(with: enter)
                }
            }
            // Wired after the enter: an enter reports the real cursor, which is somewhere else.
            if !closed { hosting.onMouseMove = { point in hover.evaluate(at: point, source: "tracking") } }
            if gap {
                let dead = await probeGap(panel: panel, hosting: hosting, hover: hover, model: model, rows: rows, x: x, height: size.height, fixture: fixture ?? "screen")
                exit(dead ? 5 : 0)
            }
            let locked = Reminder.screenLocked
            let meter = MainThreadMeter()
            meter.start()
            let began = ContinuousClock.now
            var y = top
            var down = true
            var moves = 0
            // About 200 moves a second, a row crossed every third move: a fast sweep.
            while ContinuousClock.now - began < .seconds(seconds) {
                try? await Task.sleep(for: .microseconds(4167))
                y += down ? step : -step
                if y >= bottom { y = bottom; down = false }
                if y <= top { y = top; down = true }
                // Closed: 20pt from the panel's left edge, far from the collapsed shape.
                let point = CGPoint(x: closed ? 20 : x, y: size.height - y)
                guard let event = NSEvent.mouseEvent(
                    with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
                ) else { continue }
                if closed {
                    hover.evaluate(at: panel.convertPoint(toScreen: point), source: "global")
                } else {
                    // The local monitor, then the tracking area (which also feeds SwiftUI's hover).
                    hover.evaluate(at: panel.convertPoint(toScreen: point), source: "local")
                    hosting.mouseMoved(with: event)
                }
                moves += 1
            }
            meter.stop()
            // A locked screen renders differently and roughly doubles every number: not a result.
            if locked || Reminder.screenLocked {
                print("bench: the screen was locked during the run, no result")
                exit(4)
            }
            let entries = haptics.count
            let busy = meter.busyMilliseconds
            print(String(format: "bench: %.1fs, %d moves, %d row entries, open %@, main thread busy %.0f ms (%.0f%%), %.2f ms per row entry, %.3f ms per move",
                         meter.wallSeconds, moves, entries, model.isOpen ? "yes" : "no", busy, 100 * busy / (meter.wallSeconds * 1000),
                         entries > 0 ? busy / Double(entries) : 0, moves > 0 ? busy / Double(moves) : 0))
            try? FileManager.default.removeItem(at: silent)
            exit(closed ? (model.isOpen ? 3 : 0) : (entries > 0 && model.isOpen ? 0 : 3))
        }
        app.run()
    }
}

extension HoverBench {
    /// See `run`: steps down the card, renders the hosting view at each height and reads which
    /// pills are filled. True when some height has none, two, or not the hovered one.
    static func probeGap(panel: NSPanel, hosting: NSView, hover: HoverController, model: NotchModel, rows: [TaskList.Row], x: CGFloat, height: CGFloat, fixture: String) async -> Bool {
        let geometry = model.geometry
        let card = model.shapeRect
        let map = CardMap(notchHeight: geometry.notchHeight, taskCount: rows.count)
        let bodyLeft = card.minX + NotchGeometry.flare
        // Where a filled pill shows and nothing else draws: 3pt inside its left end, at its middle.
        let sampleX = bodyLeft + Lanes.pillInset + 3
        var sampled: [(name: String, y: CGFloat)] = [("row 1", geometry.notchHeight / 2)]
        for index in 1..<rows.count { sampled.append(("row \(index + 1)", map.center(ofTask: index))) }
        sampled.append(("add card", map.addTop + OpenLayout.addHeight / 2))
        let left = bodyLeft + Lanes.pillInset + 1
        let right = bodyLeft + Lanes.pillWidth(contentWidth: model.openWidth) + Lanes.pillInset - 1
        var failed = false
        print(String(format: "bench gap: %@, %@, band %.0fpt tall, rows 28pt from y %.0f, add card from y %.0f, card %.0fpt wide",
                     fixture, geometry.hasHardwareNotch ? "hardware notch" : "in the menu bar row", geometry.notchHeight, map.rowsTop, map.addTop, model.openWidth))
        for column in [x, left, right] {
            var owner: [(y: CGFloat, drawn: String)] = []
            var probe = geometry.notchHeight / 2
            let end = map.addTop + OpenLayout.addHeight / 2
            while probe <= end {
                let point = CGPoint(x: column, y: height - probe)
                if let event = NSEvent.mouseEvent(
                    with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
                ) {
                    hover.evaluate(at: panel.convertPoint(toScreen: point), source: "local")
                    (hosting as? NSHostingView<NotchView>)?.mouseMoved(with: event)
                }
                try? await Task.sleep(for: .milliseconds(1))
                // What the screen would show: the hosting view drawn into a bitmap.
                hosting.layoutSubtreeIfNeeded()
                var lit: [String] = []
                // A 4pt strip down the card through the sample points is enough, and fast.
                let strip = CGRect(x: sampleX - 2, y: 0, width: 4, height: hosting.bounds.height)
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: strip) {
                    hosting.cacheDisplay(in: strip, to: rep)
                    let scale = CGFloat(rep.pixelsWide) / strip.width
                    for sample in sampled {
                        let color = rep.colorAt(x: Int(2 * scale), y: Int((card.minY + sample.y) * scale))
                        if (color?.whiteComponentValue ?? 0) > 0.03 { lit.append(sample.name) }
                    }
                }
                let logical = sampled.first { name in
                    switch model.hover {
                    case .task(let index): return name.name == "row \(index + 1)"
                    case .add: return name.name == "add card"
                    default: return false
                    }
                }?.name
                let drawn = lit.count == 1 ? lit[0] : (lit.isEmpty ? "NOTHING" : lit.joined(separator: " and "))
                if lit.count != 1 || lit.first != logical { failed = true }
                owner.append((probe, drawn + (lit.count == 1 && lit.first != logical ? " (hover state says \(logical ?? "nothing"))" : "")))
                probe += 1
            }
            var start = 0
            for index in owner.indices where index == owner.count - 1 || owner[index + 1].drawn != owner[index].drawn {
                print(String(format: "bench gap: x %.0f, y %.1f to %.1f: %@ drawn", column, owner[start].y, owner[index].y, owner[index].drawn))
                start = index + 1
            }
        }
        print("bench gap: " + (failed ? "dead zone found" : "no dead zone") + ", " + fixture + String(format: " (band %.0fpt tall, rows 28pt from y %.0f)", geometry.notchHeight, map.rowsTop))
        return failed
    }
}

extension NSColor {
    /// Brightness as gray, for a sampled pixel.
    var whiteComponentValue: CGFloat { usingColorSpace(.deviceGray)?.whiteComponent ?? 0 }
}

/// Stands in for the trackpad: counts the ticks, performs nothing.
final class CountingPerformer: NSObject, NSHapticFeedbackPerformer {
    nonisolated(unsafe) var count = 0
    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern, performanceTime: NSHapticFeedbackManager.PerformanceTime) {
        count += 1
    }
}

/// Main thread time spent outside the run loop's wait, from a run loop observer.
@MainActor
final class MainThreadMeter {
    private var observer: CFRunLoopObserver?
    private var awake: UInt64?
    private var busy: UInt64 = 0
    private var began: UInt64 = 0
    private var ended: UInt64 = 0

    var busyMilliseconds: Double { Double(busy) / 1e6 }
    var wallSeconds: Double { Double(ended - began) / 1e9 }

    func start() {
        began = DispatchTime.now().uptimeNanoseconds
        awake = began
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if activity == .afterWaiting {
                    self.awake = now
                } else if let awake = self.awake {
                    self.busy += now - awake
                    self.awake = nil
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func stop() {
        ended = DispatchTime.now().uptimeNanoseconds
        if let awake { busy += ended - awake }
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }
}
