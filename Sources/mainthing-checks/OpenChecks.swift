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

    section("OpenLayout")
    do {
        let screen: CGFloat = 2560
        check("row chrome is the two paddings, 32", OpenLayout.rowChrome == 32)
        check("short list keeps the 300 minimum", OpenLayout.width(titleWidths: [120, 80, 200], screenWidth: screen) == 300)
        check("empty list keeps the minimum", OpenLayout.width(titleWidths: [], screenWidth: screen) == 300)
        check("a long title sets the width", OpenLayout.width(titleWidths: [120, 350.4], screenWidth: screen) == 383)
        check("the 440 cap holds", OpenLayout.width(titleWidths: [900], screenWidth: screen) == 440)
        check("half of a tiny screen caps below 440", OpenLayout.width(titleWidths: [900], screenWidth: 800) == 400)
        check("width cap is the smaller of 440 and half the screen", OpenLayout.widthCap(screenWidth: 1512) == 440 && OpenLayout.widthCap(screenWidth: 700) == 350)
        check("title width is the card minus the chrome", OpenLayout.titleWidth(contentWidth: 300) == 268)
        check("titles never wrap", OpenLayout.maxLines == 1)

        check("content height: rows, spacing, padding", OpenLayout.contentHeight(rowHeights: [22, 18, 18]) == 2 + 58 + 12 + 14)
        check("content height with two note lines", OpenLayout.contentHeight(rowHeights: [22]) + 2 * (14 + 6) == OpenLayout.contentHeight(rowHeights: [22], notes: 2))
        check("content height of an empty list is one line", OpenLayout.contentHeight(rowHeights: []) == 2 + 18 + 14)

        let small = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 100, screenHeight: 1440, minimum: 260)
        check("a short card keeps the 260 minimum and does not scroll", small.panel == 260 && small.rowsMax == nil)
        let mid = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 400, screenHeight: 1440, minimum: 260)
        check("a taller card grows the panel with 40pt headroom", mid.panel == 470 && mid.rowsMax == nil)
        let tall = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 2000, screenHeight: 1440, minimum: 260)
        check("past 60 percent of the screen the panel caps at 864", tall.panel == 864)
        check("and the rows scroll inside what is left", tall.rowsMax == 864 - 30 - 40 - 2 - 14)
        let edge = OpenLayout.panelHeight(notchHeight: 30, contentHeight: 794, screenHeight: 1440, minimum: 260)
        check("exactly at the cap: no scrolling", edge.panel == 864 && edge.rowsMax == nil)
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
        check("dim rows are 0.55, or 0.8 with Increase Contrast", OpenLayout.dimOpacity(increaseContrast: false) == 0.55 && OpenLayout.dimOpacity(increaseContrast: true) == 0.8)
    }
}
