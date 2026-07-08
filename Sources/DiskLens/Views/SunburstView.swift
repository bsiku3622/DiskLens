import SwiftUI

/// One drawable ring segment. Angles are absolute (radians); radius is applied
/// at draw time from the current view size, so slices survive resizing.
private struct Slice: Identifiable {
    let id: UUID
    let node: FileNode
    let depth: Int
    let a0: CGFloat
    let a1: CGFloat
    let hue: Double
}

/// Radial (sunburst) map of the focused folder's contents.
struct SunburstView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("appLanguage") private var langRaw = Lang.initial.rawValue
    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }

    private let ringGap: CGFloat = 4
    private let sliceGap: CGFloat = 0.008   // angular gap between adjacent slices (radians)
    private let outerPadding: CGFloat = 10

    private var slices: [Slice] {
        guard let focus = state.focus else { return [] }
        return Self.build(focus)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let list = slices
            ZStack {
                Canvas { ctx, sz in
                    draw(ctx, size: sz, slices: list)
                }
                centerLabel
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p):
                    let node = hitTest(p, size: size, slices: list)
                    if state.hovered?.id != node?.id { state.hovered = node }
                case .ended:
                    if state.hovered != nil { state.hovered = nil }
                }
            }
            .gesture(
                SpatialTapGesture(coordinateSpace: .local).onEnded { ev in
                    handleTap(ev.location, size: size, slices: list)
                }
            )
        }
    }

    // MARK: - Center

    private var centerLabel: some View {
        let focus = state.hovered ?? state.focus
        return VStack(spacing: 3) {
            if let focus {
                Image(systemName: Theme.icon(for: focus))
                    .font(.title3)
                    .foregroundStyle(state.focus?.parent != nil ? Color.accentColor : .secondary)
                Text(focus.name)
                    .font(.callout).bold()
                    .lineLimit(1).truncationMode(.middle)
                Text(focus.size.humanBytes)
                    .font(.title3).monospacedDigit().bold()
                if state.hovered == nil, state.focus?.parent != nil {
                    Label(L(.upToParent, lang), systemImage: "arrow.up")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 130)
        .padding(8)
    }

    // MARK: - Drawing

    private func draw(_ ctx: GraphicsContext, size: CGSize, slices: [Slice]) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) / 2 - outerPadding
        guard maxR > 20 else { return }
        let hole = maxR * Theme.holeFraction
        let ringW = (maxR - hole) / CGFloat(Theme.maxRings)
        let hoveredID = state.hovered?.id

        for slice in slices {
            let inner = hole + CGFloat(slice.depth) * ringW
            let outer = inner + ringW - ringGap
            // Inset the angular span a touch so neighboring slices read as separate.
            let g = min(sliceGap / 2, (slice.a1 - slice.a0) / 3)
            let path = donut(c, inner, outer, slice.a0 + g, slice.a1 - g)
            let isHot = slice.node.id == hoveredID
            ctx.fill(path, with: .color(Theme.color(hue: slice.hue, depth: slice.depth, hovered: isHot)))
            if isHot {
                ctx.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            }
        }
    }

    private func donut(_ c: CGPoint, _ inner: CGFloat, _ outer: CGFloat,
                       _ a0: CGFloat, _ a1: CGFloat) -> Path {
        var p = Path()
        let steps = max(1, Int((a1 - a0) / (.pi / 90)))
        p.move(to: pt(c, outer, a0))
        for i in 0...steps {
            let a = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
            p.addLine(to: pt(c, outer, a))
        }
        for i in 0...steps {
            let a = a1 - (a1 - a0) * CGFloat(i) / CGFloat(steps)
            p.addLine(to: pt(c, inner, a))
        }
        p.closeSubpath()
        return p
    }

    private func pt(_ c: CGPoint, _ r: CGFloat, _ a: CGFloat) -> CGPoint {
        CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }

    // MARK: - Hit testing

    private func hitTest(_ p: CGPoint, size: CGSize, slices: [Slice]) -> FileNode? {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) / 2 - outerPadding
        guard maxR > 20 else { return nil }
        let hole = maxR * Theme.holeFraction
        let ringW = (maxR - hole) / CGFloat(Theme.maxRings)
        let dx = p.x - c.x, dy = p.y - c.y
        let r = hypot(dx, dy)
        guard r >= hole, r <= maxR else { return nil }
        let ring = Int((r - hole) / ringW)
        let ang = CGFloat(atan2(dy, dx))
        for slice in slices where slice.depth == ring {
            let width = slice.a1 - slice.a0
            let delta = norm(ang - slice.a0)
            if delta <= width { return slice.node }
        }
        return nil
    }

    private func norm(_ a: CGFloat) -> CGFloat {
        let twoPi = CGFloat.pi * 2
        var x = a.truncatingRemainder(dividingBy: twoPi)
        if x < 0 { x += twoPi }
        return x
    }

    private func handleTap(_ p: CGPoint, size: CGSize, slices: [Slice]) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) / 2 - outerPadding
        let hole = maxR * Theme.holeFraction
        let r = hypot(p.x - c.x, p.y - c.y)
        if r < hole {
            state.focusUp()
            return
        }
        if let node = hitTest(p, size: size, slices: slices) {
            state.drill(into: node)
        }
    }

    // MARK: - Layout

    private static func build(_ focus: FileNode) -> [Slice] {
        var out: [Slice] = []
        let start = -CGFloat.pi / 2

        func recurse(_ node: FileNode, depth: Int, a0: CGFloat, a1: CGFloat, hue: Double?) {
            if depth >= Theme.maxRings { return }
            let span = a1 - a0
            let total = CGFloat(max(node.size, 1))
            var a = a0
            for (i, child) in node.sortedChildren.enumerated() {
                let ca1 = a + span * (CGFloat(child.size) / total)
                if ca1 - a >= 0.006 {   // skip sub-0.35° slivers for speed + clarity
                    let h = hue ?? Theme.hue(forIndex: i)
                    out.append(Slice(id: child.id, node: child, depth: depth, a0: a, a1: ca1, hue: h))
                    recurse(child, depth: depth + 1, a0: a, a1: ca1, hue: h)
                }
                a = ca1
            }
        }
        recurse(focus, depth: 0, a0: start, a1: start + .pi * 2, hue: nil)
        return out
    }
}
