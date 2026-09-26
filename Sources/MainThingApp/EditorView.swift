import AppKit
import MainThingCore
import SwiftUI

/// What the editor's views ask of the controller. `EditorController` in the app; previews pass
/// one that does nothing.
@MainActor
protocol EditorActions {
    func rename(_ id: UUID, _ title: String)
    func remove(_ id: UUID)
    func dragRow(_ id: UUID, translation: CGFloat)
    func endDragRow()
    func moveWindow()
    func endMoveWindow()
    func caretToEnd()
    func reload()
    func overwrite()
    func cancel()
    func save()
}

extension EditorController: EditorActions {}

/// The list editor: the open card's look (black, radius 24, the same lanes and fonts) with a text
/// field on every row. Task 1 is the main thing: full white and the dot. The rest are dim until
/// hovered or focused. Hover shows a drag handle in the marker lane and a remove button on the right.
struct EditorView: View {
    let editor: EditorModel
    let notch: NotchModel
    let controller: any EditorActions

    var body: some View {
        GeometryReader { proxy in
            let size = editor.size
            card
                .frame(width: size.width, height: size.height, alignment: .top)
                // Flying in or out of the notch: the window frame animates, the content scales with it.
                .scaleEffect(
                    x: editor.morphing ? proxy.size.width / size.width : 1,
                    y: editor.morphing ? proxy.size.height / size.height : 1,
                    anchor: .topLeading
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: EditorLayout.radius, style: .continuous)
        return VStack(spacing: 0) {
            EditorRows(editor: editor, notch: notch, controller: controller)
                .padding(.top, EditorLayout.topPadding)
            EditorFooter(editor: editor, controller: controller)
                .padding(.top, EditorLayout.footerGap)
                .padding(.bottom, EditorLayout.bottomPadding)
        }
        .frame(width: EditorLayout.width, alignment: .top)
        .background(shape.fill(.black))
        .clipShape(shape)
        .contentShape(shape)
        // The card itself moves the window; rows, handles, fields and buttons keep their own drags.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in controller.moveWindow() }
                .onEnded { _ in controller.endMoveWindow() }
        )
    }
}

/// Every row, in a scroll view past 12.
struct EditorRows: View {
    let editor: EditorModel
    let notch: NotchModel
    let controller: any EditorActions
    @FocusState private var focus: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = editor.draft.rows
        let scrolls = EditorLayout.scrolls(rows: rows.count)
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        EditorRow(
                            row: row,
                            index: index,
                            dotColor: notch.dotColor,
                            dragging: editor.dragID == row.id,
                            dragOffset: editor.dragID == row.id ? editor.dragOffset : 0,
                            focus: $focus,
                            controller: controller
                        )
                        .id(row.id)
                        .zIndex(editor.dragID == row.id ? 1 : 0)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, Lanes.pillInset)
            }
            .scrollDisabled(!scrolls)
            .scrollIndicators(scrolls ? .automatic : .never)
            .frame(height: EditorLayout.rowsHeight(rows: rows.count))
            .onChange(of: editor.focusTick) { _, _ in
                // The row may be new in this very update; focus it once it is in the tree.
                let id = editor.focusRequest
                Task { @MainActor in
                    focus = id
                    if let id, scrolls { withAnimation(Motion.fade) { reader.scrollTo(id) } }
                    // Focus selects the whole title, so the first key would replace it: put the
                    // caret at the end instead, once the field editor is in place.
                    await Task.yield()
                    controller.caretToEnd()
                }
            }
            .onChange(of: focus) { _, id in
                editor.focused = id
                if let id, scrolls { withAnimation(Motion.fade) { reader.scrollTo(id) } }
            }
        }
        .animation(reduceMotion ? nil : Motion.content(reduceMotion), value: rows.map(\.id))
    }
}

/// One row: [marker lane: dot, number or handle][title field][remove].
struct EditorRow: View {
    let row: DraftRow
    let index: Int
    let dotColor: Color
    let dragging: Bool
    let dragOffset: CGFloat
    var focus: FocusState<UUID?>.Binding
    let controller: any EditorActions
    @State private var hovering = false

    var body: some View {
        let first = index == 0
        let lifted = hovering || dragging || focus.wrappedValue == row.id
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let titleOpacity = first ? 1 : Lanes.rowTitleOpacity(hovered: lifted, increaseContrast: contrast)
        let pill = RoundedRectangle(cornerRadius: Lanes.pillRadius, style: .continuous)
        HStack(spacing: Lanes.gap) {
            marker(first: first, lifted: lifted, contrast: contrast)
                .frame(width: Lanes.markerSlot, height: Lanes.rowHeight)
            TextField("", text: Binding(
                get: { row.title },
                set: { controller.rename(row.id, $0) }
            ), prompt: Text("New task").foregroundStyle(.white.opacity(0.25)))
                .textFieldStyle(.plain)
                .font(first ? NotchMetrics.font : NotchMetrics.rowFont)
                .foregroundStyle(.white.opacity(titleOpacity))
                .focused(focus, equals: row.id)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(first ? "Task 1, the main thing" : "Task \(index + 1)")
            Button {
                controller.remove(row.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(RowButtonStyle())
            .opacity(hovering && !dragging ? 1 : 0)
            .allowsHitTesting(hovering && !dragging)
            .accessibilityLabel("Remove")
        }
        .padding(.horizontal, Lanes.pillPadding)
        .frame(width: Lanes.pillWidth(contentWidth: EditorLayout.width), height: Lanes.rowHeight)
        .background(pill.fill(.white.opacity(lifted ? Lanes.pillOpacity : 0)))
        .offset(y: dragOffset)
        // The dragged row stays under the cursor: it takes its new slot at once while the others
        // slide, and its offset makes up the difference in the same frame.
        .transaction { if dragging { $0.animation = nil } }
        .onHover { inside in withAnimation(Motion.preview) { hovering = inside } }
    }

    /// Task 1's dot or the row number; the drag handle while hovered or dragged.
    @ViewBuilder
    private func marker(first: Bool, lifted: Bool, contrast: Bool) -> some View {
        ZStack {
            if hovering || dragging {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(dragging ? 0.9 : 0.55))
                    .transition(.opacity)
            } else if first {
                Dot(sweep: 0, color: dotColor)
                    .transition(.opacity)
            } else {
                Text(String(index + 1))
                    .font(NotchMetrics.numberFont)
                    .foregroundStyle(.white.opacity(Lanes.numberOpacity(hovered: lifted, increaseContrast: contrast)))
                    .transition(.opacity)
            }
        }
        .frame(width: Lanes.markerSlot, height: Lanes.rowHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in controller.dragRow(row.id, translation: value.translation.height) }
                .onEnded { _ in controller.endDragRow() }
        )
        .accessibilityLabel("Reorder")
    }
}

/// Cancel and Save, or, after a Save that found the list changed, the message with Reload and Overwrite.
struct EditorFooter: View {
    let editor: EditorModel
    let controller: any EditorActions

    var body: some View {
        VStack(alignment: .leading, spacing: EditorLayout.messageGap) {
            if editor.conflict {
                Text("The list changed while you were editing")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(height: EditorLayout.messageHeight)
                    .padding(.leading, Lanes.rowTextStart)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if editor.conflict {
                    EditorButton(title: "Reload", primary: false) { controller.reload() }
                    EditorButton(title: "Overwrite", primary: true) { controller.overwrite() }
                } else {
                    EditorButton(title: "Cancel", primary: false) { controller.cancel() }
                    EditorButton(title: "Save", primary: true) { controller.save() }
                }
            }
            .padding(.horizontal, Lanes.pillInset + Lanes.pillPadding)
        }
        .frame(width: EditorLayout.width, alignment: .leading)
    }
}

struct EditorButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: primary ? .semibold : .regular))
                .foregroundStyle(primary ? .black : .white.opacity(hovering ? 0.95 : 0.75))
                .padding(.horizontal, 12)
                .frame(height: EditorLayout.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: Lanes.pillRadius, style: .continuous)
                        .fill(primary ? .white.opacity(hovering ? 1 : 0.92) : .white.opacity(hovering ? 0.14 : 0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .onHover { inside in withAnimation(Motion.preview) { hovering = inside } }
    }
}
