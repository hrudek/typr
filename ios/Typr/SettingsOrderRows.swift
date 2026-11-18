import SwiftUI

// Adapted from AVGVSTVS96/iikb App/Design/OrderRows.swift (MIT).
/// Rows put in order by dragging the handle at their left, for a `SettingsSection`. VoiceOver moves a row
/// with Move up and Move down. The order is saved once, when the row is let go, and a drag the system takes
/// away (a scroll, a call) puts the rows back as they were.
struct SettingsOrderRows<Item: Hashable, Label: View>: View {
    @Binding var items: [Item]
    @ViewBuilder var label: (Item) -> Label

    @State private var dragging: [Item]?
    @State private var lifted: Item?
    @State private var start = 0
    @State private var lift: CGFloat = 0
    @State private var pitch: CGFloat = 64
    @GestureState private var held = false

    private var shown: [Item] { dragging ?? items }

    var body: some View {
        ForEach(Array(shown.enumerated()), id: \.element) { index, item in
            HStack(spacing: 12) {
                handle(item)
                label(item)
                    .accessibilityActions {
                        if index > 0 { Button("Move up") { move(item, to: index - 1) } }
                        if index < shown.count - 1 { Button("Move down") { move(item, to: index + 1) } }
                    }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .overlay(alignment: .top) {
                if index > 0, lifted == nil { SettingsDivider() }
            }
            .background(
                lifted == item ? TyprTheme.bgBase : .clear,
                in: RoundedRectangle(cornerRadius: TyprTheme.cardRadius)
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pitch = $0 }
            .offset(y: lifted == item ? lift : 0)
            .shadow(color: .black.opacity(lifted == item ? 0.18 : 0), radius: 10, y: 3)
            .zIndex(lifted == item ? 1 : 0)
            .sensoryFeedback(.selection, trigger: lifted == item ? dragging : nil)
            .onChange(of: held) { _, isHeld in
                if !isHeld, lifted == item { settle(saving: false) }
            }
        }
    }

    private func handle(_ item: Item) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.body.weight(.medium))
            .foregroundStyle(TyprTheme.textMuted)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle().inset(by: -12))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($held) { _, held, _ in held = true }
                    .onChanged { drag in
                        if lifted == nil {
                            dragging = items
                            lifted = item
                            start = items.firstIndex(of: item) ?? 0
                        }
                        guard var order = dragging, let at = order.firstIndex(of: item) else { return }
                        let to = min(max(start + Int((drag.translation.height / pitch).rounded()), 0), order.count - 1)
                        if to != at {
                            order.move(fromOffsets: [at], toOffset: to > at ? to + 1 : to)
                            withAnimation(.snappy(duration: 0.2)) { dragging = order }
                        }
                        lift = drag.translation.height - CGFloat(to - start) * pitch
                    }
                    .onEnded { _ in settle(saving: true) }
            )
            .accessibilityHidden(true)
    }

    private func settle(saving: Bool) {
        if saving, let dragging, dragging != items { items = dragging }
        if !saving { withAnimation(.snappy(duration: 0.25)) { dragging = items } }
        withAnimation(.snappy(duration: 0.25)) {
            lift = 0
            lifted = nil
        } completion: {
            dragging = nil
        }
    }

    private func move(_ item: Item, to index: Int) {
        guard let at = items.firstIndex(of: item) else { return }
        withAnimation(.snappy) { items.move(fromOffsets: [at], toOffset: index > at ? index + 1 : index) }
    }
}
