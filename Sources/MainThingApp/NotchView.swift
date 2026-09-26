import AppKit
import MainThingCore
import SwiftUI
import os

/// The notch. Collapsed: a black shape at the top center with the current task inside.
/// Open: every task flush left, the current one large; hover previews a cross off, a click draws it.
struct NotchView: View {
    let store: TaskStore
    let model: NotchModel
    var sounds: Sounds? = nil
    var reminder: Reminder? = nil
    var onToggle: (TaskList.Row) -> Void = { _ in }
    /// Rename, discard, add and undo from the fields, the menu and VoiceOver. Nil in previews.
    var card: CardController? = nil

    var body: some View {
        VStack(spacing: 0) {
            NotchBody(store: store, model: model, sounds: sounds, reminder: reminder, onToggle: onToggle, card: card)
                // The hosting view fills the panel, so the global space is panel space, origin top left.
                // A GeometryReader preference in the background never delivered the laid out frame here
                // (it fired once with zero), so the shape rect goes through onGeometryChange instead.
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { rect in
                    viewLog.debug("shape rect \(NSStringFromRect(rect), privacy: .public)")
                    model.shapeRect = rect
                    if let started = model.openStartedAt, rect.height > model.geometry.notchHeight + 1 {
                        model.openStartedAt = nil
                        let took = (ContinuousClock.now - started).components
                        let ms = Double(took.seconds) * 1000 + Double(took.attoseconds) / 1e15
                        viewLog.notice("open layout \(ms, format: .fixed(precision: 1), privacy: .public) ms after the open started")
                    }
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private let viewLog = Logger(subsystem: MainThingBundleID, category: "hover")

struct NotchBody: View {
    let store: TaskStore
    let model: NotchModel
    let sounds: Sounds?
    let reminder: Reminder?
    let onToggle: (TaskList.Row) -> Void
    var card: CardController? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = store.list.rows
        let keys = rows.map(\.key)
        let geometry = model.geometry
        let collapsedWidth = NotchMetrics.width(for: rows.first?.title, minimum: geometry.minimumWidth)
        let countWidth = rows.isEmpty ? 0 : NotchMetrics.countWidth(rows.count)
        // The band is never cut: the open card is at least the collapsed band plus the count.
        let openWidth = max(Lanes.bandWidth(collapsedWidth: collapsedWidth, countWidth: countWidth), model.openWidth)
        // The shape width springs between these. Content is laid out at its own final width,
        // never at the animating width, and the clip hides the overflow while the spring settles.
        let width = model.isOpen ? openWidth : collapsedWidth
        let shape = NotchShape(
            topRadius: NotchMetrics.flare,
            bottomRadius: model.isOpen ? NotchMetrics.openBottomRadius : NotchMetrics.bottomRadius
        )
        VStack(spacing: 0) {
            // The band, hanging under the menu bar: the dot and task 1 in both states. Its frame
            // width is what animates, and the band is leading aligned, so the dot and the title
            // ride with the card's left edge and never re-align or swap.
            BandSlot(store: store, model: model, width: width, card: card, onToggle: onToggle)
            if model.isOpen {
                OpenContent(store: store, model: model, onToggle: onToggle, width: openWidth, card: card)
                    .transition(Motion.openContent(reduceMotion))
            }
        }
        // The long press menu, on its row, card coordinates.
        .overlay(alignment: .topLeading) { MenuLayer(model: model, card: card) }
        .padding(.horizontal, NotchMetrics.flare)
        // Pure black, no translucency: it must match a hardware notch.
        .background(shape.fill(.black))
        .clipShape(shape)
        .contentShape(shape)
        .animation(Motion.shape(reduceMotion, opening: model.isOpen), value: model.isOpen)
        .animation(Motion.size(reduceMotion, open: model.isOpen), value: keys)
        .animation(Motion.size(reduceMotion, open: model.isOpen), value: model.openWidth)
        .contextMenu { NotchMenu(store: store, sounds: sounds, reminder: reminder) }
    }
}

/// The band as the model has it now. Its own view, so a hover or a drag step redraws the band
/// and the rows, never the card around them.
struct BandSlot: View {
    let store: TaskStore
    let model: NotchModel
    let width: CGFloat
    var card: CardController?
    let onToggle: (TaskList.Row) -> Void

    var body: some View {
        let rows = store.list.rows
        let first = rows.first
        let held = first != nil && model.drag?.key == first?.key
        Band(
            rows: rows,
            width: width,
            height: model.geometry.notchHeight,
            isOpen: model.isOpen,
            struck: first.map { model.pending.isPending($0.key) } ?? false,
            sweep: model.sweep,
            dotColor: model.dotColor,
            flash: Gradient(stops: NotchMetrics.shimmerStops(core: model.flashCore, edge: model.flashEdge)),
            taskTime: model.taskTime,
            hovered: model.isOpen && model.hover == .task(0),
            pressed: model.pressed == .task(0),
            lift: model.drag == nil ? 0 : model.shift(ofTask: 0, centers: CardMap(model: model, store: store).liveCenters),
            held: held,
            menuOpen: first != nil && model.menu?.key == first?.key,
            quiet: model.quietRows,
            rename: model.isOpen && first != nil && model.renaming == first?.key ? Bindable(model).renameText : nil,
            card: card,
            onToggle: { if let first { onToggle(first) } }
        )
        // Held, task 1 rides over the rows.
        .zIndex(held ? 1 : 0)
    }
}

/// The long press menu over its row, in card coordinates.
struct MenuLayer: View {
    let model: NotchModel
    var card: CardController?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if model.isOpen, let menu = model.menu {
            RowMenuView(menu: menu, card: card)
                .offset(x: menu.frame.minX, y: menu.frame.minY)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
        }
    }
}

/// The band: the pink dot in the marker lane, then the current task in the text lane, left
/// aligned at the card padding. One view in both states, so nothing swaps on open; open, the
/// count "1 of N" sits right aligned. A task change pushes the new title in; each title keeps its
/// own natural width, so a title that fits never truncates while the shape width animates around
/// it. Open, task 1 is a row like the others: its pill (`Lanes.bandPill`), inset 8 like the row
/// pills, fills on hover and the title previews the cross off. The hover comes from the card's one
/// tracker (`NotchModel.hover`), the same state for every row. The dot, title and count keep their
/// lanes: inset 8 plus padding 10 is the band's 18. Held by its dot, the pill, the dot and the
/// title follow the pointer and the count stays. Empty list: nothing, the plain notch.
struct Band: View {
    let rows: [TaskList.Row]
    let width: CGFloat
    let height: CGFloat
    let isOpen: Bool
    let struck: Bool
    /// Reminder sweeps so far; each bump runs the shimmer and the dot pulse.
    let sweep: Int
    /// The color clock: the dot now, the band of the step last reached, the dot's tooltip.
    let dotColor: Color
    let flash: Gradient
    let taskTime: String
    /// The pointer is on task 1, open.
    let hovered: Bool
    let pressed: Bool
    /// How far task 1 shows from its place while a task is held.
    var lift: CGFloat = 0
    /// Task 1 is the held one: lifted, on black, no animation of its own.
    var held = false
    /// The long press menu is on task 1: lifted, no cross off preview.
    var menuOpen = false
    /// A reorder or rename just landed: the new title is just there, no push.
    var quiet = false
    /// The rename field's text while task 1 is being renamed.
    var rename: Binding<String>? = nil
    var card: CardController? = nil
    let onToggle: () -> Void
    @State private var countShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.previewPins) private var pins
    private var hovering: Bool { hovered || held || rename != nil || (pins.hovered != nil && pins.hovered == rows.first?.key) }

    var body: some View {
        let pill = Lanes.bandPill(width: width, height: height)
        ZStack(alignment: .leading) {
            if let current = rows.first {
                content(current, pill: pill)
                    .background {
                        // Rides with the animating edge like the count, and fades in on the
                        // count's schedule, the same rise as the first row. The fill shows on
                        // hover; held, it sits on black so the rows under it do not show through.
                        ZStack {
                            if held {
                                RoundedRectangle(cornerRadius: Lanes.pillRadius, style: .continuous).fill(.black)
                            }
                            RoundedRectangle(cornerRadius: Lanes.pillRadius, style: .continuous)
                                .fill(.white.opacity(hovering && isOpen ? Lanes.pillOpacity : 0))
                        }
                        .opacity(countShown ? 1 : 0)
                    }
                    .opacity(pressed ? 0.85 : 1)
                    .animation(Motion.press, value: pressed)
                    .offset(y: lift)
                    // Held: exactly under the pointer, never behind it on a spring.
                    .transaction { if held { $0.animation = nil } }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(current.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(struck ? "Crossed off, leaving. Click again to keep it" : "Click to cross off")
                    .accessibilityAction { onToggle() }
                    .accessibilityAction(named: "Cross off") { onToggle() }
                    .accessibilityAction(named: "Rename") { card?.startRename(current.key) }
                    .accessibilityAction(named: "Discard") { card?.discard(current.key) }
            }
        }
        .frame(width: pill.width, height: pill.height, alignment: .leading)
        .overlay(alignment: .trailing) {
            // Always in the tree, so it rides with the animating right edge instead of landing on
            // the final one; opacity and a 4pt rise come in on their own transaction.
            if !rows.isEmpty {
                Text(Lanes.countText(rows.count))
                    .font(NotchMetrics.countFont)
                    .foregroundStyle(.white.opacity(Lanes.countOpacity))
                    .padding(.trailing, Lanes.trailingPadding - pill.minX)
                    .opacity(countShown && !menuOpen ? 1 : 0)
                    .offset(y: countShown || reduceMotion ? 0 : 4)
                    .accessibilityHidden(!isOpen)
            }
        }
        .padding(.leading, pill.minX)
        .frame(width: width, height: height, alignment: .leading)
        .onChange(of: isOpen, initial: true) { _, open in
            withAnimation(Motion.countFade(reduceMotion, opening: open)) { countShown = open }
        }
        .animation(Motion.content(reduceMotion), value: rows.map(\.key))
    }

    /// The dot and the title (or its rename field), laid out in the pill's frame.
    private func content(_ current: TaskList.Row, pill: CGRect) -> some View {
        HStack(spacing: Lanes.gap) {
            Dot(sweep: sweep, color: dotColor)
                .frame(width: Lanes.markerSlot, height: Lanes.markerSlot)
                .help(taskTime)
            if let rename {
                InlineField(text: rename, font: NotchMetrics.font, prompt: current.title, keepsFocus: false,
                            onSubmit: { card?.submitRename() }, onCancel: { card?.cancelRename() })
                    .frame(width: Lanes.bandTitleWidth(contentWidth: width, countWidth: NotchMetrics.countWidth(rows.count)), alignment: .leading)
            } else {
                ZStack(alignment: .leading) {
                    Text(current.title)
                        .font(NotchMetrics.font)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .modifier(Ink(
                            progress: struck ? pins.ink ?? 1 : 0,
                            preview: hovered && isOpen && !struck && !held && !menuOpen ? 1 : 0,
                            key: current.key,
                            xHeight: NotchMetrics.nsFont.xHeight,
                            thickness: 3.2,
                            inkOpacity: 1,
                            // Reduce Motion: the dot pulses, the title stays still.
                            shimmer: reduceMotion ? 0 : pins.sweep ?? Double(sweep),
                            flash: flash
                        ))
                        .animation(reduceMotion ? nil : (struck ? .linear(duration: PenStroke.secondsPerLine) : Motion.unstrike), value: struck)
                        .frame(width: menuOpen ? min(NotchMetrics.titleWidth(for: current.title), RowMenu.titleLimit(cardWidth: width)) : NotchMetrics.titleWidth(for: current.title), alignment: .leading)
                        .id(current.key)
                        .transition(quiet ? .identity : Motion.push(reduceMotion))
                }
            }
        }
        .padding(.leading, Lanes.slotStart - pill.minX)
        .frame(width: pill.width, height: pill.height, alignment: .leading)
    }
}

/// The dot: 7pt with a soft glow of its own color, the color clock's color of the moment. On
/// each reminder sweep it pulses once, scale 1 to 1.25 and back with the glow up; under Reduce
/// Motion a slower, smaller pulse. The keyframes drive frames only while they run.
struct Dot: View {
    let sweep: Int
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Pulse {
        var scale: CGFloat = 1
        var glow: Double = NotchMetrics.dotGlowOpacity
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: NotchMetrics.dotSize, height: NotchMetrics.dotSize)
            .keyframeAnimator(initialValue: Pulse(), trigger: sweep) { dot, pulse in
                dot
                    .scaleEffect(pulse.scale)
                    .shadow(color: color.opacity(pulse.glow), radius: NotchMetrics.dotGlow)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(reduceMotion ? 1.12 : 1.25, duration: reduceMotion ? 0.9 : 0.5)
                    CubicKeyframe(1, duration: reduceMotion ? 1.1 : 0.7)
                }
                KeyframeTrack(\.glow) {
                    CubicKeyframe(1, duration: reduceMotion ? 0.9 : 0.5)
                    CubicKeyframe(NotchMetrics.dotGlowOpacity, duration: reduceMotion ? 1.1 : 0.7)
                }
            }
    }
}

/// The body of the open card under the band: rows 2..N as pills in the same lanes, dim so the
/// main thing stays the focus, an Undo row where a task was just discarded, and the add card at
/// the very bottom. Past 60 percent of the screen the rows scroll.
struct OpenContent: View {
    let store: TaskStore
    let model: NotchModel
    let onToggle: (TaskList.Row) -> Void
    let width: CGFloat
    var card: CardController? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.previewPins) private var pins

    var body: some View {
        let rows = store.list.rows
        let keys = rows.map(\.key)
        let map = CardMap(model: model, store: store)
        let centers = map.liveCenters
        VStack(alignment: .leading, spacing: 0) {
            if map.isEmpty {
                Text("No tasks")
                    .font(NotchMetrics.rowFont)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(height: OpenLayout.emptyHeight)
                    .padding(.leading, Lanes.textStart - Lanes.pillInset)
                    .transition(.opacity)
            } else {
                RowsBlock(maxHeight: model.rowsMaxHeight, onScroll: { model.rowsScroll = $0 }) {
                    VStack(alignment: .leading, spacing: 0) {
                        // By key, so a row that moves or leaves keeps its identity and the rest slide.
                        ForEach(RowItem.items(map: map, rows: rows)) { entry in
                            item(entry.slot, position: entry.position, rows: rows, centers: centers)
                        }
                    }
                    .animation(Motion.content(reduceMotion), value: keys)
                }
            }
            if !model.apiBound {
                Note("API off on port " + String(model.apiPort))
            }
            // A hook or adapter whose last run failed, until it next succeeds.
            ForEach(store.events.failing, id: \.self) { label in
                Note("sync failed: " + label)
                    .transition(.opacity)
            }
            if model.adding {
                FieldRow(marker: .plus, text: Bindable(model).addText, prompt: "New task", keepsFocus: true,
                         onSubmit: { card?.submitAdd() }, onCancel: { card?.closeAdd() }, width: width)
                    .transition(.opacity)
            } else {
                // Folded into the bottom padding until the pointer reaches it, then a row tall.
                let shows = model.hover == .add || pins.add
                AddCard(width: width, hovered: shows, pressed: model.pressed == .add)
                    .equatable()
                    .frame(height: shows ? OpenLayout.addHeight : 0, alignment: .top)
                    .clipped()
                    .animation(Motion.content(reduceMotion), value: shows)
                    .accessibilityAction { card?.openAdd() }
            }
        }
        .padding(.horizontal, Lanes.pillInset)
        .padding(.top, Lanes.topGap)
        .padding(.bottom, Lanes.bottomPadding)
        // Laid out at the final open width. The width itself does not animate here.
        .frame(width: width, alignment: .leading)
        .animation(nil, value: width)
        .animation(Motion.content(reduceMotion), value: keys)
    }

    /// One row under the band: a task, its rename field, or the Undo.
    @ViewBuilder
    private func item(_ slot: CardSlot, position: Int, rows: [TaskList.Row], centers: [CGFloat]) -> some View {
        switch slot {
        case .task(let index) where rows.indices.contains(index):
            let row = rows[index]
            let held = model.drag?.key == row.key
            // Lifted, with no cross off preview: held, or the long press menu is on it.
            let lifted = held || model.menu?.key == row.key
            Group {
                if model.renaming == row.key {
                    FieldRow(marker: .number(index + 1), text: Bindable(model).renameText, prompt: row.title, keepsFocus: false,
                             onSubmit: { card?.submitRename() }, onCancel: { card?.cancelRename() }, width: width)
                } else {
                    TaskRow(
                        row: row,
                        number: index + 1,
                        struck: model.pending.isPending(row.key),
                        width: width,
                        hovered: model.hover == .task(index) || pins.hovered == row.key,
                        pressed: model.pressed == .task(index),
                        held: lifted,
                        menuOpen: model.menu?.key == row.key
                    )
                    .equatable()
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(model.pending.isPending(row.key) ? "Crossed off, leaving. Click again to keep it" : "Click to cross off")
                    .accessibilityAction { onToggle(row) }
                    .accessibilityAction(named: "Cross off") { onToggle(row) }
                    .accessibilityAction(named: "Rename") { card?.startRename(row.key) }
                    .accessibilityAction(named: "Discard") { card?.discard(row.key) }
                }
            }
            .offset(y: model.shift(ofTask: index, centers: centers))
            // Held: exactly under the pointer, never behind it on a spring.
            .transaction { if held { $0.animation = nil } }
            .zIndex(held ? 1 : 0)
            .transition(model.quietRows ? .identity : Motion.row(reduceMotion, index: position))
        case .undo:
            if let gone = model.discarded {
                UndoRow(title: gone.task.title, width: width, hovered: model.hover == .undo || pins.undo, pressed: model.pressed == .undo)
                    .equatable()
                    .accessibilityAction { card?.undo() }
                    .transition(.opacity.animation(reduceMotion ? Motion.reducedFade : Motion.fade))
            }
        default:
            EmptyView()
        }
    }
}

/// One row under the band, keyed by its task (or "undo"), with its position.
struct RowItem: Identifiable {
    let id: String
    let slot: CardSlot
    let position: Int

    static func items(map: CardMap, rows: [TaskList.Row]) -> [RowItem] {
        (0..<map.rowItems).map { position in
            let slot = map.item(atRow: position)
            if case .task(let index) = slot, rows.indices.contains(index) {
                return RowItem(id: rows[index].key, slot: slot, position: position)
            }
            return RowItem(id: "undo", slot: slot, position: position)
        }
    }
}

/// A small line under the rows, in the text lane.
struct Note: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
            .lineLimit(1)
            .frame(height: OpenLayout.noteHeight)
            .padding(.top, OpenLayout.noteSpacing)
            .padding(.leading, Lanes.textStart - Lanes.pillInset)
    }
}

/// The rows, plain when they fit, in a scroll view when they do not. The clipped edge gets a
/// short fade instead of a hard cut: at the bottom while more rows are below, at the top once scrolled.
struct RowsBlock<Content: View>: View {
    private let fadeHeight: CGFloat = 18
    let maxHeight: CGFloat?
    /// How far the rows are scrolled, for the pointer map.
    var onScroll: (CGFloat) -> Void = { _ in }
    @ViewBuilder let content: Content
    @State private var topClipped = false
    @State private var bottomClipped = false

    var body: some View {
        if let maxHeight {
            ScrollView(.vertical) {
                content
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("rows"))
                    } action: { frame in
                        topClipped = frame.minY < -1
                        bottomClipped = frame.maxY > maxHeight + 1
                    }
            }
            .coordinateSpace(name: "rows")
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                onScroll(offset)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: maxHeight)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: topClipped ? fadeHeight : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: bottomClipped ? fadeHeight : 0)
                }
            }
            .animation(Motion.edgeFade, value: topClipped)
            .animation(Motion.edgeFade, value: bottomClipped)
        } else {
            content
                .onAppear { onScroll(0) }
        }
    }
}

/// One line of the Sound submenu: a checkmark on the current choice; picking one previews it.
struct SoundItem: View {
    let choice: SoundChoice
    let current: SoundChoice
    let sounds: Sounds

    var body: some View {
        Toggle(choice.displayName, isOn: Binding(
            get: { current == choice },
            set: { on in if on { sounds.choose(choice) } }
        ))
    }
}

/// One of rows 2..N: a 28pt pill with the row number in the marker lane and the title in the
/// text lane, one line; a title wider than the card truncates with an ellipsis and shows in full
/// as a tooltip. Hover (from the card's one tracker) fills the pill, lifts the title and the
/// number, and shows a faint preview of the cross off; a click draws it like a pen on paper, and
/// 400ms later the row leaves. A click in that window erases the ink and keeps the row. Plain
/// data and Equatable: a hover change redraws only the two rows it moved between.
struct TaskRow: View, Equatable {
    let row: TaskList.Row
    let number: Int
    let struck: Bool
    /// Card content width, for the pill and the line count the pen has to cross.
    let width: CGFloat
    let hovered: Bool
    let pressed: Bool
    /// Held by its number: lifted, on black, following the pointer.
    var held = false
    /// The long press menu is open on this row: the title ends before it.
    var menuOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.previewPins) private var pins

    nonisolated static func == (a: TaskRow, b: TaskRow) -> Bool {
        a.row == b.row && a.number == b.number && a.struck == b.struck && a.width == b.width
            && a.hovered == b.hovered && a.pressed == b.pressed && a.held == b.held && a.menuOpen == b.menuOpen
    }

    var body: some View {
        let hovering = hovered || held
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let titleOpacity = Lanes.rowTitleOpacity(hovered: hovering, increaseContrast: contrast)
        let numberOpacity = Lanes.numberOpacity(hovered: hovering, increaseContrast: contrast)
        let titleWidth = NotchMetrics.rowTitleWidth(row.title)
        let truncated = ceil(titleWidth) > OpenLayout.titleWidth(contentWidth: width)
        let pill = RoundedRectangle(cornerRadius: Lanes.pillRadius, style: .continuous)
        HStack(spacing: Lanes.gap) {
            // The hover dims and lifts through opacity, never through the text's own color: an
            // animated color re-resolves the text and runs TextKit layout again on every frame.
            Text(String(number))
                .font(NotchMetrics.numberFont)
                .foregroundStyle(.white)
                .opacity(numberOpacity)
                .frame(width: Lanes.markerSlot)
            // A hover change never reaches the renderer: rerunning it lays the text out again
            // on every frame. Unstruck, the title dims with a plain opacity and the preview is a
            // shape over it; struck, the renderer dims the glyphs so the ink stays at full strength.
            Text(row.title)
                .font(NotchMetrics.rowFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(Ink(
                    progress: struck ? pins.ink ?? 1 : 0,
                    preview: 0,
                    textOpacity: struck ? titleOpacity : 1,
                    key: row.key,
                    xHeight: NotchMetrics.rowNSFont.xHeight,
                    thickness: 2.8,
                    inkOpacity: Lanes.rowTitleOpacity(hovered: true, increaseContrast: contrast),
                    shimmer: 0
                ))
                .opacity(struck ? 1 : titleOpacity)
                .frame(maxWidth: menuOpen ? RowMenu.titleLimit(cardWidth: width) : .infinity, alignment: .leading)
                // The pen: linear over 220ms with the ease inside the renderer, so the ink grows from
                // the left end to the right. Undo: a fast erase. Reduce Motion: the ink is just there.
                .animation(reduceMotion ? nil : (struck ? .linear(duration: PenStroke.secondsPerLine) : Motion.unstrike), value: struck)
                .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                    PreviewStroke(key: row.key, lineWidth: titleWidth, xHeight: NotchMetrics.rowNSFont.xHeight)
                        .fill(.white.opacity(NotchMetrics.previewOpacity))
                        .frame(height: PreviewStroke.height)
                        .alignmentGuide(.firstTextBaseline) { _ in PreviewStroke.height }
                        .opacity(hovered && !held && !struck ? 1 : 0)
                        // The click hides it at once, as the renderer did when the ink started.
                        .animation(nil, value: struck)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Lanes.pillPadding)
        .padding(.trailing, Lanes.pillTrailingPadding)
        .frame(width: Lanes.pillWidth(contentWidth: width), height: Lanes.rowHeight, alignment: .leading)
        .background {
            // Held, the fill sits on black so the rows under it do not show through.
            ZStack {
                if held { pill.fill(.black) }
                pill.fill(.white.opacity(Lanes.pillOpacity)).opacity(hovering ? 1 : 0)
            }
        }
        .opacity(pressed ? 0.85 : 1)
        .animation(Motion.press, value: pressed)
        .help(truncated ? row.title : "")
    }
}

/// A row whose title is a text field: a rename in place, or the add card opened. The marker lane
/// keeps the row number, or shows the plus. Return and Escape go to the card.
struct FieldRow: View {
    enum Marker { case number(Int), plus }

    let marker: Marker
    @Binding var text: String
    let prompt: String
    /// Return keeps the field focused, for another task.
    let keepsFocus: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let width: CGFloat

    var body: some View {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        HStack(spacing: Lanes.gap) {
            Group {
                switch marker {
                case .number(let number):
                    Text(String(number)).font(NotchMetrics.numberFont)
                case .plus:
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .opacity(Lanes.numberOpacity(hovered: true, increaseContrast: contrast))
            .frame(width: Lanes.markerSlot)
            InlineField(text: $text, font: NotchMetrics.rowFont, prompt: prompt, keepsFocus: keepsFocus, onSubmit: onSubmit, onCancel: onCancel)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Lanes.pillPadding)
        .padding(.trailing, Lanes.pillTrailingPadding)
        .frame(width: Lanes.pillWidth(contentWidth: width), height: Lanes.rowHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Lanes.pillRadius, style: .continuous).fill(.white.opacity(Lanes.pillOpacity)))
    }
}

/// A plain one line text field on the black card: white text, a white caret, the prompt dim. It
/// takes focus as it appears; the panel is key by then.
struct InlineField: View {
    @Binding var text: String
    let font: Font
    let prompt: String
    let keepsFocus: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt).foregroundStyle(.white.opacity(0.3)))
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(.white)
            .lineLimit(1)
            .focused($focused)
            .onSubmit {
                onSubmit()
                if keepsFocus { focused = true }
            }
            .onExitCommand(perform: onCancel)
            // A dark field: a white caret and a light selection on black.
            .environment(\.colorScheme, .dark)
            .onAppear { Task { @MainActor in focused = true } }
    }
}

/// Where a discarded task was, for 4 seconds: its title faint and struck through by nothing,
/// and Undo. A click anywhere on the row puts the task back.
struct UndoRow: View, Equatable {
    let title: String
    let width: CGFloat
    let hovered: Bool
    let pressed: Bool

    var body: some View {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        HStack(spacing: Lanes.gap) {
            Color.clear.frame(width: Lanes.markerSlot)
            Text(title)
                .font(NotchMetrics.rowFont)
                .foregroundStyle(.white)
                .opacity(Lanes.numberOpacity(hovered: false, increaseContrast: contrast))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Undo")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(Lanes.rowTitleOpacity(hovered: true, increaseContrast: contrast))
        }
        .padding(.leading, Lanes.pillPadding)
        .padding(.trailing, Lanes.pillTrailingPadding)
        .frame(width: Lanes.pillWidth(contentWidth: width), height: Lanes.rowHeight, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Lanes.pillRadius, style: .continuous).fill(.white.opacity(Lanes.pillOpacity)).opacity(hovered ? 1 : 0))
        .opacity(pressed ? 0.85 : 1)
        .animation(Motion.press, value: pressed)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Undo discard of " + title)
        .accessibilityAddTraits(.isButton)
    }
}

/// The long press menu: Rename and Discard side by side on black, a hairline edge, the item
/// under the pointer lit. The card's pointer picks the item; the views only draw.
struct RowMenuView: View {
    let menu: CardMenu
    var card: CardController? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 0) {
            ForEach(RowMenu.Item.allCases, id: \.self) { item in
                Text(item.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .opacity(menu.hovered == item ? 1 : 0.75)
                    .frame(width: RowMenu.itemWidth, height: RowMenu.height - 2 * RowMenu.padding)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(menu.hovered == item ? 0.14 : 0)))
                    .accessibilityElement()
                    .accessibilityLabel(item.rawValue)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { card?.choose(item, on: menu.key) }
            }
        }
        .padding(RowMenu.padding)
        .frame(width: RowMenu.width, height: RowMenu.height)
        .background(shape.fill(.black))
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}

/// The add card at the very bottom of the open card: nothing until the pointer is on it, then a
/// row's hover, a plus in the marker lane and "New task" in the text lane.
struct AddCard: View, Equatable {
    let width: CGFloat
    let hovered: Bool
    let pressed: Bool

    var body: some View {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        HStack(spacing: Lanes.gap) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(Lanes.numberOpacity(hovered: true, increaseContrast: contrast))
                .frame(width: Lanes.markerSlot)
            Text("New task")
                .font(NotchMetrics.rowFont)
                .foregroundStyle(.white)
                .opacity(Lanes.rowTitleOpacity(hovered: false, increaseContrast: contrast))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Lanes.pillPadding)
        .padding(.trailing, Lanes.pillTrailingPadding)
        .frame(width: Lanes.pillWidth(contentWidth: width), height: OpenLayout.addHeight, alignment: .leading)
        .opacity(hovered ? 1 : 0)
        .background(RoundedRectangle(cornerRadius: Lanes.pillRadius, style: .continuous).fill(.white.opacity(Lanes.pillOpacity)).opacity(hovered ? 1 : 0))
        .opacity(pressed ? 0.85 : 1)
        .animation(Motion.press, value: pressed)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New task")
        .accessibilityAddTraits(.isButton)
    }
}

/// The hover preview of the cross off over a one line title: the hand drawn path the click will
/// ink, thinner and whole, on the middle of the x-height. Its bottom edge sits on the title's
/// baseline; it spans the title's width, or the frame when the title is cut.
struct PreviewStroke: Shape {
    /// Tall enough for the x-height and the stroke's wobble above the baseline.
    static let height: CGFloat = 16
    var key: String
    var lineWidth: CGFloat
    var xHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let y = rect.maxY - xHeight / 2
        let samples = PenStroke.centerline(
            from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.minX + min(lineWidth, rect.width), y: y), line: 0,
            seed: PenStroke.seed(key: key, line: 0), thickness: NotchMetrics.previewThickness
        )
        let outline = PenStroke.outline(samples, progress: 1)
        var path = Path()
        guard outline.count >= 3 else { return path }
        path.move(to: outline[0])
        for point in outline.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

/// The animatable half: SwiftUI interpolates a modifier's `animatableData`, so the progress and
/// the preview live here and the renderer below only draws.
struct Ink: ViewModifier, @preconcurrency Animatable {
    var progress: Double
    var preview: Double
    /// The glyphs' opacity. It animates here, in the renderer, instead of in the text's color.
    var textOpacity: Double = 1
    var key: String
    var xHeight: CGFloat
    var thickness: CGFloat
    var inkOpacity: Double
    /// The reminder sweep counter; on its way from n to n + 1 the band crosses the title.
    var shimmer: Double
    /// The band: clear ends, the step's lighter edge, its core.
    var flash: Gradient = Gradient(stops: NotchMetrics.shimmerStops(core: NotchMetrics.pink, edge: NotchMetrics.pinkEdge))

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(progress, preview), AnimatablePair(shimmer, textOpacity)) }
        set {
            progress = newValue.first.first
            preview = newValue.first.second
            shimmer = newValue.second.first
            textOpacity = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        content.textRenderer(CrossOffRenderer(
            progress: progress, preview: preview, textOpacity: textOpacity, key: key, xHeight: xHeight, thickness: thickness, inkOpacity: inkOpacity,
            shimmer: ReminderSchedule.phase(of: shimmer), flash: flash
        ))
    }
}

/// Draws the title and the ink over it. `progress` runs 0...lineCount: line 0 is crossed while it
/// goes 0 to 1, line 1 while it goes 1 to 2 (titles are one line now, the loop stays general).
/// `preview` fades a thin line in on hover. `shimmer` 0...1 is the reminder band's progress: a
/// pink gradient, masked to the glyphs, crossing the title left to right; 0 draws nothing.
struct CrossOffRenderer: TextRenderer {
    var progress: Double
    var preview: Double
    var textOpacity: Double = 1
    var key: String
    var xHeight: CGFloat
    var thickness: CGFloat
    var inkOpacity: Double
    var shimmer: Double
    var flash: Gradient

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let lines = Array(layout)
        for (index, line) in lines.enumerated() {
            let bounds = line.typographicBounds
            let t = PenStroke.lineProgress(progress, line: index)
            // The glyphs, dimming to 45 percent as the ink passes.
            let glyphOpacity = textOpacity * (1 - 0.55 * t)
            if shimmer > 0 {
                // The band, kept to the glyphs: draw them in a layer, then paint the gradient
                // source atop. Clear ends leave the white; the middle is pink with a lighter edge.
                let band = ReminderSchedule.band(phase: shimmer, width: bounds.rect.width)
                let y = bounds.rect.midY
                let start = CGPoint(x: bounds.rect.minX + band.start, y: y)
                let end = CGPoint(x: bounds.rect.minX + band.end, y: y)
                context.drawLayer { layer in
                    layer.opacity = glyphOpacity
                    layer.draw(line)
                    layer.opacity = 1
                    layer.blendMode = .sourceAtop
                    layer.fill(Path(bounds.rect), with: .linearGradient(flash, startPoint: start, endPoint: end))
                }
            } else {
                var glyphs = context
                glyphs.opacity = glyphOpacity
                glyphs.draw(line)
            }

            // The strike line sits on the middle of the x-height of this line.
            let y = bounds.rect.minY + bounds.ascent - xHeight / 2
            let from = CGPoint(x: bounds.rect.minX, y: y)
            let to = CGPoint(x: bounds.rect.maxX, y: y)

            if preview > 0, t == 0 {
                // The same hand drawn path the click will ink, thinner and translucent, whole at once.
                let samples = PenStroke.centerline(
                    from: from, to: to, line: index,
                    seed: PenStroke.seed(key: key, line: index), thickness: NotchMetrics.previewThickness
                )
                let outline = PenStroke.outline(samples, progress: 1)
                if outline.count >= 3 {
                    var path = Path()
                    path.move(to: outline[0])
                    for point in outline.dropFirst() { path.addLine(to: point) }
                    path.closeSubpath()
                    context.fill(path, with: .color(.white.opacity(NotchMetrics.previewOpacity * preview)))
                }
            }
            if t > 0 {
                let samples = PenStroke.centerline(
                    from: from, to: to, line: index,
                    seed: PenStroke.seed(key: key, line: index), thickness: thickness
                )
                let outline = PenStroke.outline(samples, progress: t)
                if outline.count >= 3 {
                    var path = Path()
                    path.move(to: outline[0])
                    for point in outline.dropFirst() { path.addLine(to: point) }
                    path.closeSubpath()
                    context.fill(path, with: .color(.white.opacity(inkOpacity)))
                }
            }
        }
    }
}

/// Right click menu: Launch at Login, Sound, Reminder, Show Tasks File, Install Command Line Tool, Quit.
struct NotchMenu: View {
    let store: TaskStore
    let sounds: Sounds?
    let reminder: Reminder?

    var body: some View {
        if LaunchAtLogin.needsApproval {
            Button("Launch at Login: approve in System Settings") { LaunchAtLogin.openSettings() }
        } else {
            Toggle("Launch at Login", isOn: Binding(
                get: { LaunchAtLogin.isEnabled },
                set: { on in
                    do {
                        let status = try LaunchAtLogin.setEnabled(on)
                        if status == .requiresApproval { LaunchAtLogin.openSettings() }
                    } catch {
                        NSSound.beep()
                    }
                }
            ))
        }
        if let sounds {
            // Read fresh every time the menu opens, so a file dropped into the folder shows up.
            let files = sounds.available()
            let current = SoundChoice.resolve(stored: Sounds.stored, available: files)
            Menu("Sound") {
                SoundItem(choice: .pen, current: current, sounds: sounds)
                ForEach(files, id: \.self) { file in
                    SoundItem(choice: .custom(fileName: file), current: current, sounds: sounds)
                }
                Divider()
                SoundItem(choice: .off, current: current, sounds: sounds)
            }
        }
        if reminder != nil {
            // Read fresh every time the menu opens; `defaults write` can change it too.
            let current = Reminder.interval
            Menu("Reminder") {
                ForEach(ReminderSchedule.menuMinutes, id: \.self) { minutes in
                    Toggle(ReminderSchedule.label(minutes: minutes), isOn: Binding(
                        get: { current == minutes * 60 },
                        set: { on in if on { Reminder.store(seconds: minutes * 60) } }
                    ))
                }
            }
        }
        Button("Show Tasks File") {
            NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
        }
        Button("Install Command Line Tool") { CommandLineTool.installFromMenu() }
        Divider()
        UpdateMenuItems()
        Button("Settings…") { SettingsWindow.show() }
        Divider()
        Button("Quit Main Thing") { NSApp.terminate(nil) }
    }
}

/// Sizes shared by the view and the width measurement.
enum NotchMetrics {
    /// The current task, in the band, collapsed or open.
    static let font = Font.system(size: 13.5, weight: .semibold)
    @MainActor static let nsFont = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    static let pink = Color(red: 1, green: 0x4F / 255, blue: 0x9A / 255)
    static let pinkEdge = Color(red: 1, green: 0x9E / 255, blue: 0xCB / 255)
    /// The reminder band across the title: clear ends, the step's lighter edge, its core.
    static func shimmerStops(core: Color, edge: Color) -> [Gradient.Stop] {
        [
            .init(color: .clear, location: 0),
            .init(color: edge, location: 0.3),
            .init(color: core, location: 0.5),
            .init(color: edge, location: 0.7),
            .init(color: .clear, location: 1),
        ]
    }
    static let dotSize: CGFloat = 7
    static let dotGlow: CGFloat = 8
    static let dotGlowOpacity: Double = 0.7
    /// The other tasks in the open state, and their row numbers.
    static let rowFont = Font.system(size: 13)
    @MainActor static let rowNSFont = NSFont.systemFont(ofSize: 13)
    static let numberFont = Font.system(size: 11, weight: .medium).monospacedDigit()
    /// "1 of N" in the open band.
    static let countFont = Font.system(size: 11, weight: .medium)
    @MainActor static let countNSFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// The hover preview of the cross off: thinner and translucent next to the real ink.
    static let previewThickness: CGFloat = 1.6
    static let previewOpacity: Double = 0.55
    static let flare = NotchGeometry.flare
    static let bottomRadius: CGFloat = 12
    static let openBottomRadius: CGFloat = 24

    /// Collapsed notch width before the flares: the dot, the title and the padding, clamped.
    /// `minimum` comes from the geometry: plain 169, or the camera housing width.
    @MainActor static func width(for title: String?, minimum: CGFloat = NotchGeometry.housingWidth - 2 * NotchGeometry.flare) -> CGFloat {
        guard let title, !title.isEmpty else { return minimum }
        let text = (title as NSString).size(withAttributes: [.font: nsFont]).width
        return Lanes.collapsedWidth(titleWidth: text, minimum: minimum)
    }

    /// The band title's own width: its single line width, capped where the collapsed notch caps.
    @MainActor static func titleWidth(for title: String) -> CGFloat {
        min(ceil((title as NSString).size(withAttributes: [.font: nsFont]).width), Lanes.collapsedTitleWidth)
    }

    /// A row title's single line width, unrounded. Measured once per title: a row's body runs on
    /// every hover change.
    @MainActor static func rowTitleWidth(_ title: String) -> CGFloat {
        if let width = rowTitleWidths[title] { return width }
        if rowTitleWidths.count > 256 { rowTitleWidths.removeAll() }
        let width = (title as NSString).size(withAttributes: [.font: rowNSFont]).width
        rowTitleWidths[title] = width
        return width
    }
    @MainActor private static var rowTitleWidths: [String: CGFloat] = [:]

    /// Single line width of "1 of N".
    @MainActor static func countWidth(_ count: Int) -> CGFloat {
        ceil((Lanes.countText(count) as NSString).size(withAttributes: [.font: countNSFont]).width)
    }
}

/// A notch outline: flared top corners that meet the screen edge, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.height / 2)
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control: CGPoint(x: rect.minX + t, y: rect.minY)
        )
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addArc(
            center: CGPoint(x: rect.minX + t + b, y: rect.maxY - b),
            radius: b, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.maxX - t - b, y: rect.maxY - b),
            radius: b, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - t, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}
