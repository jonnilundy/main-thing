import CoreGraphics
import Foundation
import MainThingCore

@MainActor
func runOpenChecks() {
    section("Complete by key")
    do {
        var list = TaskList(["A", TaskItem("B", ref: "ob:2"), "C"])
        check("key(at:) 0 based", list.key(at: 0) == "A#0" && list.key(at: 2) == "C#0" && list.key(at: 3) == nil && list.key(at: -1) == nil)
        check("key(ref:)", list.key(ref: "ob:2") == "ref:ob:2" && list.key(ref: "ob:9") == nil)
        check("complete the third row by key", list.complete(key: "C#0", expected: nil) == TaskItem("C") && list.titles == ["A", "B"])
        check("complete a ref'd row by key", list.complete(key: "ref:ob:2", expected: "B") == TaskItem("B", ref: "ob:2") && list.titles == ["A"])
        check("stale title on the key does nothing", list.complete(key: "A#0", expected: "Not A") == nil && list.titles == ["A"])
        check("unknown key does nothing", list.complete(key: "Z#0", expected: nil) == nil && list.titles == ["A"])
        check("complete(expected:) is the first key", list.complete(expected: "A") == TaskItem("A") && list.isEmpty)
    }

    section("POST /tasks/done target")
    do {
        let list = TaskList(["A", TaskItem("B", ref: "ob:2"), "C"])
        let host = ["host": "localhost"]
        check("empty body: the first", MainThingRouter.doneTarget(body: Data(), list: list) == .success("A#0"))
        check("{} body: the first", MainThingRouter.doneTarget(body: Data("{}".utf8), list: list) == .success("A#0"))
        check("empty body on an empty list: nothing", MainThingRouter.doneTarget(body: Data(), list: TaskList()) == .success(nil))
        check("index 2", MainThingRouter.doneTarget(body: Data("{\"index\":2}".utf8), list: list) == .success("C#0"))
        check("index 3 is 404", MainThingRouter.doneTarget(body: Data("{\"index\":3}".utf8), list: list) == .failure(RouteFailure(404, "no task at index 3, the list has 3")))
        check("negative index is 404", MainThingRouter.doneTarget(body: Data("{\"index\":-1}".utf8), list: list) == .failure(RouteFailure(404, "no task at index -1, the list has 3")))
        check("string index is 400", MainThingRouter.doneTarget(body: Data("{\"index\":\"2\"}".utf8), list: list) == .failure(RouteFailure(400, "index must be a whole number, 0 based")))
        check("index 1 and 0 are numbers, not booleans", MainThingRouter.doneTarget(body: Data("{\"index\":1}".utf8), list: list) == .success("ref:ob:2") && MainThingRouter.doneTarget(body: Data("{\"index\":0}".utf8), list: list) == .success("A#0"))
        check("boolean index is 400", MainThingRouter.doneTarget(body: Data("{\"index\":true}".utf8), list: list) == .failure(RouteFailure(400, "index must be a whole number, 0 based")))
        check("fractional index is 400", MainThingRouter.doneTarget(body: Data("{\"index\":1.5}".utf8), list: list).isFailure)
        check("ref", MainThingRouter.doneTarget(body: Data("{\"ref\":\"ob:2\"}".utf8), list: list) == .success("ref:ob:2"))
        check("unknown ref is 404", MainThingRouter.doneTarget(body: Data("{\"ref\":\"ob:9\"}".utf8), list: list) == .failure(RouteFailure(404, "no task with ref ob:9")))
        check("other body is 400", MainThingRouter.doneTarget(body: Data("[1]".utf8), list: list).isFailure)
        check("other keys are 400", MainThingRouter.doneTarget(body: Data("{\"title\":\"A\"}".utf8), list: list).isFailure)

        let byIndex = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host, body: Data("{\"index\":2}".utf8)), list: list)
        check("POST /tasks/done {index:2} removes C", byIndex.action == .complete(key: "C#0", source: "api") && byIndex.list.titles == ["A", "B"] && byIndex.changed)
        let byRef = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host, body: Data("{\"ref\":\"ob:2\"}".utf8)), list: list)
        check("POST /tasks/done {ref} removes B", byRef.action == .complete(key: "ref:ob:2", source: "api") && byRef.list.titles == ["A", "C"])
        let missing = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host, body: Data("{\"index\":7}".utf8)), list: list)
        check("POST /tasks/done past the end is 404 and changes nothing", missing.response.status == 404 && missing.action == .none && missing.list == list)
        let empty = MainThingRouter.handle(HTTPRequest(method: "POST", path: "/tasks/done", headers: host), list: TaskList())
        check("POST /tasks/done on empty is 200 and asks nothing", empty.response.status == 200 && empty.action == .none)
    }

    section("Lanes")
    do {
        check("band: padding 18, slot 18, gap 10, so the title starts at 46", Lanes.slotStart == 18 && Lanes.markerSlot == 18 && Lanes.gap == 10 && Lanes.textStart == 46)
        check("row: inset 8 and padding 10 put the slot at 18 and the title at 46, the same lanes", Lanes.rowSlotStart == 18 && Lanes.rowTextStart == 46 && Lanes.rowTextStart == Lanes.textStart)
        check("collapsed chrome is 70: the lanes plus the 24pt right padding", Lanes.collapsedChrome == 70 && Lanes.trailingPadding == 24)
        check("collapsed width fits dot, title and padding", Lanes.collapsedWidth(titleWidth: 200.2, minimum: 169) == 271)
        check("collapsed width keeps the minimum", Lanes.collapsedWidth(titleWidth: 40, minimum: 169) == 169 && Lanes.collapsedWidth(titleWidth: 40, minimum: 204) == 204)
        check("no title: the minimum", Lanes.collapsedWidth(titleWidth: nil, minimum: 169) == 169 && Lanes.collapsedWidth(titleWidth: 0, minimum: 169) == 169)
        check("collapsed width caps at 600", Lanes.collapsedWidth(titleWidth: 900, minimum: 169) == 600 && Lanes.collapsedTitleWidth == 530)
        check("rows rise in 20ms apart", Lanes.rowDelay(index: 0) == 0 && Lanes.rowDelay(index: 1) == 0.02 && Lanes.rowDelay(index: 3) == 0.06)
        check("the stagger caps at 120ms", Lanes.rowDelay(index: 6) == 0.12 && Lanes.rowDelay(index: 40) == 0.12 && Lanes.rowDelay(index: -1) == 0)
    }

    section("OpenLayout")
    do {
        let screen: CGFloat = 2560
        check("row chrome is 70: the lanes plus the 16pt trailing pill padding and inset", Lanes.rowChrome == 70 && Lanes.pillTrailingPadding == 16)
        check("short rows keep the 300 minimum", OpenLayout.width(bandWidth: 220, rowTitleWidths: [120, 80, 200], screenWidth: screen) == 300)
        check("no rows keeps the minimum", OpenLayout.width(bandWidth: 220, rowTitleWidths: [], screenWidth: screen) == 300)
        check("a long row title sets the width", OpenLayout.width(bandWidth: 220, rowTitleWidths: [120, 350.4], screenWidth: screen) == 421)
        check("the 440 cap holds for rows", OpenLayout.width(bandWidth: 220, rowTitleWidths: [900], screenWidth: screen) == 440)
        check("the band is never cut: a wide band wins over the cap", OpenLayout.width(bandWidth: 512.5, rowTitleWidths: [900], screenWidth: screen) == 513)
        check("half of a tiny screen caps below 440", OpenLayout.width(bandWidth: 220, rowTitleWidths: [900], screenWidth: 800) == 400)
        check("width cap is the smaller of 440 and half the screen", OpenLayout.widthCap(screenWidth: 1512) == 440 && OpenLayout.widthCap(screenWidth: 700) == 350)
        check("row title width is the card minus the chrome", OpenLayout.titleWidth(contentWidth: 300) == 230)
        check("titles never wrap", OpenLayout.maxLines == 1)
        check("band width: the collapsed band plus the gap and the count", Lanes.bandWidth(collapsedWidth: 265, countWidth: 30.2) == 265 + 12 + 31)
        check("band title lane: the card minus the lanes, the count and the padding", Lanes.bandTitleWidth(contentWidth: 400, countWidth: 30) == 400 - 46 - 12 - 30 - 24)
        check("the band title always fits next to the count", Lanes.bandTitleWidth(contentWidth: Lanes.bandWidth(collapsedWidth: Lanes.collapsedWidth(titleWidth: 200.2, minimum: 169), countWidth: 30), countWidth: 30) == 201)
        check("count text", Lanes.countText(5) == "1 of 5")
        check("pill: inset 8, radius 8, 28 high, 10 above the bottom", Lanes.pillWidth(contentWidth: 300) == 284 && Lanes.pillRadius == 8 && Lanes.rowHeight == 28 && Lanes.bottomPadding == 10 && Lanes.topGap == 6)

        check("content height: gap 6, four pills, the add card, padding 10", OpenLayout.contentHeight(rows: 4) == 6 + 112 + 28 + 10)
        check("content height with two note lines", OpenLayout.contentHeight(rows: 1) + 2 * (6 + 14) == OpenLayout.contentHeight(rows: 1, notes: 2))
        check("content height with only task 1 is the gap, the add card and the padding", OpenLayout.contentHeight(rows: 0) == 6 + 28 + 10)
        check("content height of an empty list is one line and the add card", OpenLayout.contentHeight(rows: 0, empty: true) == 6 + 18 + 28 + 10)

        let small = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 100, screenHeight: 1440, minimum: 260)
        check("a short card keeps the 260 minimum and does not scroll", small.panel == 260 && small.rowsMax == nil)
        let mid = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 400, screenHeight: 1440, minimum: 260)
        check("a taller card grows the panel with 40pt headroom", mid.panel == 470 && mid.rowsMax == nil)
        let tall = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 2000, screenHeight: 1440, minimum: 260)
        check("past 60 percent of the screen the panel caps at 864", tall.panel == 864)
        check("and the rows scroll inside what is left", tall.rowsMax == 864 - 30 - 40 - 6 - 28 - 10)
        let edge = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 794, screenHeight: 1440, minimum: 260)
        check("exactly at the cap: no scrolling", edge.panel == 864 && edge.rowsMax == nil)

        check("sub tasks: titles 46 percent, numbers 24", Lanes.rowTitleOpacity(hovered: false, increaseContrast: false) == 0.46 && Lanes.numberOpacity(hovered: false, increaseContrast: false) == 0.24)
        check("hovered row: title 90 percent, number 50, pill 8", Lanes.rowTitleOpacity(hovered: true, increaseContrast: false) == 0.9 && Lanes.numberOpacity(hovered: true, increaseContrast: false) == 0.5 && Lanes.pillOpacity == 0.08)
        check("increase contrast lifts the dim rows", Lanes.rowTitleOpacity(hovered: false, increaseContrast: true) == 0.8 && Lanes.numberOpacity(hovered: false, increaseContrast: true) == 0.6)
        check("count is 42 percent", Lanes.countOpacity == 0.42)
    }

    section("ReminderSchedule")
    do {
        check("default is 3 minutes", ReminderSchedule.defaultInterval == 180 && ReminderSchedule.interval(stored: nil) == 180)
        check("nonsense stored is the default", ReminderSchedule.interval(stored: -5) == 180)
        check("0 is off", ReminderSchedule.interval(stored: 0) == 0 && ReminderSchedule.nextFire(after: 100, interval: 0) == nil)
        check("any positive value counts, so a test can use 5 seconds", ReminderSchedule.interval(stored: 5) == 5 && ReminderSchedule.interval(stored: 600) == 600)
        check("next fire is one interval after the last", ReminderSchedule.nextFire(after: 1000, interval: 180) == 1180)
        check("menu: Off, 1, 3, 5, 10 minutes", ReminderSchedule.menuMinutes == [0, 1, 3, 5, 10])
        check("labels", ReminderSchedule.label(minutes: 0) == "Off" && ReminderSchedule.label(minutes: 1) == "1 minute" && ReminderSchedule.label(minutes: 10) == "10 minutes")
        check("a due sweep runs", ReminderSchedule.shouldSweep(locked: false, empty: false, crossingOff: false))
        check("skipped while the screen is locked", !ReminderSchedule.shouldSweep(locked: true, empty: false, crossingOff: false))
        check("skipped while the list is empty", !ReminderSchedule.shouldSweep(locked: false, empty: true, crossingOff: false))
        check("skipped while a cross off is drawing", !ReminderSchedule.shouldSweep(locked: false, empty: false, crossingOff: true))
        check("sweep takes 1.4s, band is 35 percent of the title", ReminderSchedule.sweepDuration == 1.4 && ReminderSchedule.bandShare == 0.35)
        check("phase is the fraction of the sweep counter, 0 at rest", ReminderSchedule.phase(of: 3) == 0 && abs(ReminderSchedule.phase(of: 3.25) - 0.25) < 1e-9 && ReminderSchedule.phase(of: 0) == 0)
        let start = ReminderSchedule.band(phase: 0, width: 200)
        check("at 0 the band is entirely left of the title", start.start == -70 && start.end == 0)
        let end = ReminderSchedule.band(phase: 1, width: 200)
        check("at 1 the band is entirely right of the title", end.start == 200 && end.end == 270)
        let mid = ReminderSchedule.band(phase: 0.5, width: 200)
        check("halfway the band is centered on the title", abs((mid.start + mid.end) / 2 - 100) < 1e-9 && mid.end - mid.start == 70)
    }

    section("ColorClock")
    do {
        let pink = ColorClock.brand
        check("the brand pink in OKLCH: L 0.69, C 0.22, hue 359", abs(pink.l - 0.6921) < 0.001 && abs(pink.c - 0.2196) < 0.001 && abs(pink.h - 358.56) < 0.05)
        check("sRGB round trips through OKLCH", OKLCH(hex: 0xFF4F9A).hex == "#FF4F9A" && OKLCH(hex: 0x1DB49D).hex == "#1DB49D")
        check("ten steps, 36 degrees apart, starting at the pink", ColorClock.steps == 10 && ColorClock.hue(step: 0) == pink.h && abs(ColorClock.hue(step: 1) - (pink.h + 36).truncatingRemainder(dividingBy: 360)) < 1e-9)
        check("step 10 is step 0 again, and negative steps wrap", ColorClock.hue(step: 10) == ColorClock.hue(step: 0) && ColorClock.hue(step: -1) == ColorClock.hue(step: 9))
        let colors = (0..<10).map { ColorClock.color(step: $0) }
        check("every step keeps the pink's lightness", colors.allSatisfy { abs($0.l - pink.l) < 1e-9 })
        check("every step fits sRGB", colors.allSatisfy(\.inGamut))
        check("step 0 is the pink itself", colors[0].hex == "#FF4F9A")
        check("ten distinct hues", Set(colors.map { Int($0.h.rounded()) }).count == 10)
        check("a hue the screen cannot saturate keeps its lightness at less chroma", colors[6].c < pink.c && abs(colors[6].l - pink.l) < 1e-9)

        let interval = 180.0
        check("at 0 the clock is step 0, progress 0, the pink", ColorClock.state(elapsed: 0, interval: interval) == ColorClock.State(step: 0, progress: 0, color: colors[0]))
        check("90s in: step 0, half way", ColorClock.state(elapsed: 90, interval: interval).step == 0 && abs(ColorClock.state(elapsed: 90, interval: interval).progress - 0.5) < 1e-9)
        check("half way the hue is 18 degrees on", abs(ColorClock.state(elapsed: 90, interval: interval).color.h - (pink.h + 18).truncatingRemainder(dividingBy: 360)) < 1e-9)
        check("180s in: step 1 just reached", ColorClock.state(elapsed: 180, interval: interval).step == 1 && ColorClock.state(elapsed: 180, interval: interval).progress == 0)
        check("step 9 at 27 minutes", ColorClock.state(elapsed: 9 * 180 + 1, interval: interval).step == 9)
        check("the clock wraps after ten steps: 30 minutes is the pink again", ColorClock.state(elapsed: 1800, interval: interval).step == 0 && ColorClock.state(elapsed: 1800, interval: interval).color == colors[0])
        check("and 33 minutes is step 1 again", ColorClock.state(elapsed: 1980, interval: interval).step == 1)
        check("off: step 0, the pink, no drift", ColorClock.state(elapsed: 5000, interval: 0) == ColorClock.State(step: 0, progress: 0, color: colors[0]) && ColorClock.nextFlash(elapsed: 5000, interval: 0) == nil)
        check("next flash: the next multiple of the interval", ColorClock.nextFlash(elapsed: 0, interval: 180) == 180 && ColorClock.nextFlash(elapsed: 181, interval: 180) == 360 && ColorClock.nextFlash(elapsed: 360, interval: 180) == 540)
        check("negative elapsed (clock set back) is step 0", ColorClock.state(elapsed: -5, interval: interval).step == 0)
        check("ticks: 10s at 3 minutes, faster at a 5s test interval, a minute when off", ColorClock.tick(interval: 180) == 10 && abs(ColorClock.tick(interval: 5) - 5.0 / 18) < 1e-9 && ColorClock.tick(interval: 0) == 60)
        let edge = ColorClock.edge(of: colors[0])
        check("the edge is lighter and softer, the same hue", edge.l > colors[0].l && edge.c < colors[0].c && edge.h == colors[0].h && edge.inGamut)

        let none = ColorClock.anchor(current: nil, firstKey: nil, now: 100)
        check("empty list: no anchor", none == nil)
        let a = ColorClock.anchor(current: nil, firstKey: "A#0", now: 100)
        check("first task anchors at now", a == ColorClock.Anchor(key: "A#0", start: 100))
        check("same key later: the anchor stays (relaunch continuity)", ColorClock.anchor(current: a, firstKey: "A#0", now: 5000) == a)
        check("a cross off: task 2 becomes task 1 and the clock resets", ColorClock.anchor(current: a, firstKey: "B#0", now: 5000) == ColorClock.Anchor(key: "B#0", start: 5000))
        check("a reorder or a new list with another first key resets", ColorClock.anchor(current: a, firstKey: "C#1", now: 6000)?.start == 6000)
        check("the list emptied: no anchor; the same task back later starts over", ColorClock.anchor(current: a, firstKey: nil, now: 7000) == nil && ColorClock.anchor(current: nil, firstKey: "A#0", now: 8000)?.start == 8000)

        check("tooltip under a minute", ColorClock.tooltip(elapsed: 30) == "On this task for under a minute")
        check("tooltip in minutes", ColorClock.tooltip(elapsed: 24 * 60 + 59) == "On this task for 24 min")
        check("tooltip in hours", ColorClock.tooltip(elapsed: 3600) == "On this task for 1 h" && ColorClock.tooltip(elapsed: 3600 * 2 + 300) == "On this task for 2 h 5 min")
    }

    section("PenStroke")
    do {
        let from = CGPoint(x: 10, y: 20), to = CGPoint(x: 210, y: 20)
        let seed = PenStroke.seed(key: "ref:openbrain:1", line: 0)
        let a = PenStroke.centerline(from: from, to: to, line: 0, seed: seed, thickness: 2)
        let b = PenStroke.centerline(from: from, to: to, line: 0, seed: seed, thickness: 2)
        check("same key and line: the same stroke every time", a == b)
        check("seed is stable", seed == PenStroke.seed(key: "ref:openbrain:1", line: 0) && seed != PenStroke.seed(key: "ref:openbrain:2", line: 0) && seed != PenStroke.seed(key: "ref:openbrain:1", line: 1))
        let other = PenStroke.centerline(from: from, to: to, line: 0, seed: PenStroke.seed(key: "B#0", line: 0), thickness: 2)
        check("another row wobbles differently", a.map(\.point.y) != other.map(\.point.y))
        check("28 samples", a.count == PenStroke.sampleCount)
        check("starts 4pt before the first glyph", a.first?.point.x == 6 && a.first?.point.y == 20)
        check("overshoots 6pt past the last glyph", a.last?.point.x == 216)
        let tiltEven = a.last!.point.y - a.first!.point.y
        check("even line tilts down, capped at 1.5pt over a long stroke", tiltEven > 0 && abs(tiltEven - 1.5) < 0.001)
        let short = PenStroke.centerline(from: from, to: CGPoint(x: 60, y: 20), line: 0, seed: seed, thickness: 2)
        check("a short stroke tilts 0.8 degrees, under the cap", abs((short.last!.point.y - short.first!.point.y) - tan(0.8 * .pi / 180) * 60) < 0.001)
        check("the whole stroke stays within 2pt of its start line", a.allSatisfy { abs($0.point.y - a.first!.point.y) <= 2 })
        let odd = PenStroke.centerline(from: from, to: to, line: 1, seed: seed, thickness: 2)
        check("odd line tilts the other way", (odd.last!.point.y - odd.first!.point.y) < 0)
        let mid = a[a.count / 2].width
        check("tapered: ends are thinner than the middle", a.first!.width < mid && a.last!.width < mid && a.first!.width == 0.6 && abs(mid - 2) < 0.02)
        let wobbles = a.enumerated().map { i, s in abs(s.point.y - (a.first!.point.y + tiltEven * CGFloat(i) / CGFloat(a.count - 1))) }
        check("wobble stays under 0.6pt", wobbles.max()! <= 0.6 && wobbles.max()! > 0.05)
        check("no wobble where the pen lands and lifts", wobbles.first! < 0.001 && wobbles.last! < 0.001)
        check("no ink at progress 0", PenStroke.outline(a, progress: 0).isEmpty)
        let half = PenStroke.outline(a, progress: 0.5)
        let full = PenStroke.outline(a, progress: 1)
        check("half the stroke reaches half way", half.map(\.x).max()! < 112 && half.map(\.x).max()! > 108)
        check("the full stroke is a closed band of top and bottom edges", full.count == 2 * a.count && full.map(\.x).max()! >= 216)
        check("eased: fast attack, slow finish", PenStroke.eased(0.25) > 0.5 && PenStroke.eased(0.5) > 0.85 && PenStroke.eased(1) == 1 && PenStroke.eased(0) == 0)
        check("lines run one after another", PenStroke.lineProgress(0.5, line: 0) > 0 && PenStroke.lineProgress(0.5, line: 1) == 0 && PenStroke.lineProgress(1.5, line: 0) == 1 && PenStroke.lineProgress(2, line: 1) == 1)
        check("the pen lifts at the last sample", PenStroke.liftPoint(a) == a.last?.point)
    }

    section("Sound choice")
    do {
        check("display name: dashes to spaces, title case", SoundChoice.displayName(fileName: "texture-scratch.mp3") == "Texture Scratch")
        check("display name keeps inner capitals", SoundChoice.displayName(fileName: "yeah-boiii.mp3") == "Yeah Boiii" && SoundChoice.displayName(fileName: "apple_pay.m4a") == "Apple Pay")
        check("display name of a single word", SoundChoice.displayName(fileName: "ding.wav") == "Ding")
        check("audio files by extension, case insensitive, no dot files", SoundChoice.isAudioFile("a.MP3") && SoundChoice.isAudioFile("b.caf") && !SoundChoice.isAudioFile("notes.txt") && !SoundChoice.isAudioFile(".DS_Store"))
        let files = ["texture-scratch.mp3", "apple-pay.mp3"]
        check("nothing stored: pen", SoundChoice.resolve(stored: nil, available: files) == .pen)
        check("pen stored", SoundChoice.resolve(stored: "pen", available: files) == .pen)
        check("off stored", SoundChoice.resolve(stored: "off", available: files) == .off)
        check("a present file", SoundChoice.resolve(stored: "apple-pay.mp3", available: files) == .custom(fileName: "apple-pay.mp3"))
        check("a missing file falls back to pen", SoundChoice.resolve(stored: "yeah-boiii.mp3", available: files) == .pen)
        check("stored values round trip", SoundChoice.custom(fileName: "x.wav").stored == "x.wav" && SoundChoice.off.stored == "off" && SoundChoice.pen.stored == "pen")
        check("display names of the fixed choices", SoundChoice.pen.displayName == "Pen" && SoundChoice.off.displayName == "Off")
        let ref = 0.136  // the pen scratch, about -17 dBFS RMS
        check("same loudness as the pen: the pen's volume", SoundLevel.volume(rms: ref, peak: 0.7, referenceRMS: ref, referenceVolume: 0.25) == 0.25)
        check("a loud file gets a low volume", SoundLevel.volume(rms: 0.4, peak: 1.0, referenceRMS: ref, referenceVolume: 0.25) == Float(0.25 * ref / 0.4))
        check("a quiet file is raised, capped at 1", SoundLevel.volume(rms: 0.01, peak: 0.05, referenceRMS: ref, referenceVolume: 0.25) == 1)
        check("never above what the peak allows", SoundLevel.volume(rms: 0.02, peak: 0.5, referenceRMS: ref, referenceVolume: 0.25) == 1 && SoundLevel.volume(rms: 0.02, peak: 0.9, referenceRMS: ref, referenceVolume: 0.25) == 1)
        check("silence keeps the reference volume", SoundLevel.volume(rms: 0, peak: 0, referenceRMS: ref, referenceVolume: 0.25) == 0.25)
    }

    section("Pending completions")
    do {
        var pending = PendingCompletions()
        check("nothing pending at first", !pending.isPending("A#0"))
        check("a click arms", pending.toggle("A#0") == .armed && pending.isPending("A#0"))
        check("finish removes it and says to complete", pending.finish("A#0") == true && !pending.isPending("A#0"))
        check("finish on a row that is not pending says no", pending.finish("A#0") == false)
        check("a second click cancels", pending.toggle("A#0") == .armed && pending.toggle("A#0") == .cancelled && !pending.isPending("A#0"))
        check("finish after a cancel says no, so nothing is completed", pending.finish("A#0") == false)
        check("a third click arms again", pending.toggle("A#0") == .armed && pending.finish("A#0") == true)
        _ = pending.toggle("B#0")
        _ = pending.toggle("C#0")
        pending.keep(only: ["C#0"])
        check("keep(only:) drops rows that left the list", !pending.isPending("B#0") && pending.isPending("C#0"))
    }
}
