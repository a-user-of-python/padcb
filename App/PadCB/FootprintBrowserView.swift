import SwiftUI

/// Browser for the user's imported KiCad footprints
/// (Documents/Footprints/*.kicad_mod, including .pretty-style folders).
///
/// Left: searchable list grouped by library folder. Right: a rendered
/// top-view preview (pads + graphics, KiCad board orientation — x
/// right, y DOWN as stored in the file) plus the footprint's metadata
/// and pad table. This is groundwork for the PCB editor: it exists so
/// an imported footprint can be eyeballed against the real thing
/// before anything depends on it.
struct FootprintBrowserView: View {
    @EnvironmentObject private var store: FootprintStore

    @State private var searchText = ""
    @State private var selectedID: String? = nil
    @State private var loadedFootprint: KiCadFootprint? = nil

    // Part 3: search and grouping are STATE, computed by the tasks
    // below — never inside body. Before part 3 every body pass
    // re-filtered all ~15.4k entries (lowercasing four fields each),
    // re-grouped them, and linearly scanned for the selection.
    /// Latest search results in the SearchIndex's ranked order.
    /// nil == browse mode (no query).
    @State private var searchResults: [FootprintEntry]? = nil
    /// Search results grouped for the list, built once per search
    /// publish (not per body pass).
    @State private var groupedSearch: [(group: String, entries: [FootprintEntry])]? = nil
    /// Browse-mode sections, rebuilt only when the footprint set changes.
    @State private var groupedBrowse: [(group: String, entries: [FootprintEntry])]? = nil
    /// id -> entry map: selection lookup and search-result mapping
    /// are dictionary hits, never linear scans.
    @State private var entryByID: [String: FootprintEntry] = [:]
    /// Precomputed search index over the current footprint set.
    @State private var searchIndex: SearchIndex = SearchIndex(rows: [])

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The sections the list shows right now (cached state in both modes).
    private var displayGroups: [(group: String, entries: [FootprintEntry])] {
        isSearching ? (groupedSearch ?? []) : (groupedBrowse ?? [])
    }

    private var selected: FootprintEntry? {
        if let selectedID, let match = entryByID[selectedID] {
            return match
        }
        return displayGroups.first?.entries.first
    }

    /// Cheap O(1) signature of the footprint set (user footprints are
    /// listed first, bundled last — see FootprintStore.footprints).
    private var footprintSignature: String {
        let firstID = store.userFootprints.first?.id ?? store.bundledFootprints.first?.id ?? ""
        let lastID = store.bundledFootprints.last?.id ?? store.userFootprints.last?.id ?? ""
        return "\(store.userFootprints.count + store.bundledFootprints.count)|\(firstID)|\(lastID)"
    }

    private var searchSignature: String {
        "\(searchText)\u{1}\(entryByID.count)"
    }

    private static func groupEntries(_ entries: [FootprintEntry])
        -> [(group: String, entries: [FootprintEntry])] {
        let byGroup = Dictionary(grouping: entries, by: \.group)
        return byGroup.keys.sorted().map { (group: $0, entries: byGroup[$0] ?? []) }
    }

    /// Rebuilds the entry map, the search index and the browse
    /// grouping from the store's current footprint set. Runs from a
    /// .task keyed on footprintSignature — once per actual change.
    private func rebuildFootprintScope() {
        let all = store.footprints
        entryByID = Dictionary(all.map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        searchIndex = SearchIndex(rows: all.map {
            SearchRow(id: $0.id,
                      fields: [$0.name, $0.group, $0.description,
                               $0.tags.joined(separator: " ")])
        })
        groupedBrowse = Self.groupEntries(all)
    }

    /// Debounced search, mirroring SymbolChooserView: ~80 ms sleep,
    /// the SearchIndex scan runs on a detached task, results are
    /// mapped through the entry dictionary and published on the main
    /// actor; cancellation plus a final query check keep stale
    /// results from ever landing.
    private func runSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchResults = nil
            groupedSearch = nil
            return
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard !Task.isCancelled else { return }
        let index = searchIndex
        let byID = entryByID
        let results = await Task.detached(priority: .userInitiated) { () -> [FootprintEntry] in
            index.search(query).compactMap { rowIndex in
                guard rowIndex >= 0, rowIndex < index.rows.count else { return nil }
                return byID[index.rows[rowIndex].id]
            }
        }.value
        guard !Task.isCancelled else { return }
        guard searchText.trimmingCharacters(in: .whitespaces) == query else { return }
        searchResults = results
        groupedSearch = Self.groupEntries(results)
    }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            VStack(spacing: 0) {
                searchBar
                Divider()
                HStack(spacing: 0) {
                    listPane
                        .frame(width: 340)
                    Divider()
                    detailPane
                }
            }
        }
        .navigationTitle("Footprint Browser")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.rescan()
                } label: {
                    HStack(spacing: 6) {
                        if store.isScanning {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise").lineLimit(1)
                        }
                        Text("Rescan").lineLimit(1)
                    }
                }
                .disabled(store.isScanning)
            }
        }
        .task { store.bootstrap() }
        .task(id: footprintSignature) {
            rebuildFootprintScope()
        }
        .task(id: searchSignature) {
            await runSearch()
        }
        .task(id: selected?.id) {
            // Bundled footprints parse on demand (the corpus is ~15k
            // files); user footprints arrive already parsed.
            if let selected {
                loadedFootprint = store.footprint(for: selected)
            } else {
                loadedFootprint = nil
            }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            TextField("Search footprints — name, library, tags", text: $searchText)
                .autocorrectionDisabled()
                .lineLimit(1)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Text("\(store.userFootprints.count + store.bundledFootprints.count) imported")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.12))
    }

    // MARK: - List

    @ViewBuilder
    private var listPane: some View {
        if store.footprints.isEmpty && !store.isScanning {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.square")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("No footprints imported yet.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("In the Files app, drop .kicad_mod files into PadCB ▸ Footprints (a .pretty folder works too), then tap Rescan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !store.issues.isEmpty {
                    Section {
                        ForEach(Array(store.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(3)
                        }
                    } header: {
                        Text("Skipped files")
                    }
                }
                ForEach(displayGroups, id: \.group) { group in
                    Section(group.group) {
                        ForEach(group.entries) { entry in
                            Button {
                                selectedID = entry.id
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(entry.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        if entry.source == .user {
                                            Text("YOURS")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(.black)
                                                .lineLimit(1)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color.green, in: Capsule())
                                        }
                                    }
                                    Text("\(entry.padCount) pads · \(entry.fileName)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                selected?.id == entry.id
                                    ? Color.accentColor.opacity(0.30) : Color.clear)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let entry = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Text(entry.key)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(entry.source == .user ? "Your import" : "KiCad library")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(entry.source == .user ? Color.green : Color.white.opacity(0.75),
                                        in: Capsule())
                    }
                    if let loadedFootprint {
                        preview(entry, footprint: loadedFootprint)
                            .frame(height: 340)
                            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                        metadata(entry, footprint: loadedFootprint)
                        padTable(entry, footprint: loadedFootprint)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("Parsing footprint…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(height: 340)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Select a footprint to preview it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metadata(_ entry: FootprintEntry, footprint fp: KiCadFootprint) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            if !fp.description.isEmpty {
                metaBlock("Description", fp.description)
            }
            if !fp.tags.isEmpty {
                metaRow("Tags", fp.tags.joined(separator: " "))
            }
            metaRow("File", entry.relativePath)
            metaRow("Pads", "\(fp.pads.count) (\(fp.pads.filter { $0.isThroughHole }.count) through-hole, \(fp.pads.filter { !$0.isThroughHole }.count) SMD/other)")
            metaRow("Graphics", "\(fp.graphics.count)")
            if !fp.layers.isEmpty {
                metaRow("Layers", fp.layers.joined(separator: ", "))
            }
            if !fp.attributes.isEmpty {
                metaRow("Attributes", fp.attributes.joined(separator: ", "))
            }
            if !fp.skippedNodeCounts.isEmpty {
                let skipped = fp.skippedNodeCounts
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key) ×\($0.value)" }
                    .joined(separator: ", ")
                metaRow("Not modelled", skipped)
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }

    private func metaBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(4)
        }
    }

    private func padTable(_ entry: FootprintEntry, footprint fp: KiCadFootprint) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pads")
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            ForEach(Array(fp.pads.enumerated()), id: \.offset) { _, pad in
                HStack(spacing: 8) {
                    Text(pad.number.isEmpty ? "—" : pad.number)
                        .font(.callout.weight(.bold))
                        .lineLimit(1)
                        .frame(width: 44, alignment: .leading)
                    Text("\(pad.type.rawValue) \(pad.shape.rawValue)")
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(format(pad.width))×\(format(pad.height)) mm")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let drill = pad.drill {
                        Text("drill \(format(drill.width))\(drill.isOval ? "×\(format(drill.height))" : "") mm")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(pad.layers.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
    }

    // MARK: - Preview rendering

    /// Top view in file coordinates: x right, y DOWN (KiCad board
    /// orientation). The file->screen map is a plain fit + translate,
    /// with NO y flip — flipping it would mirror the footprint.
    private func preview(_ entry: FootprintEntry, footprint fp: KiCadFootprint) -> some View {
        return Canvas { ctx, size in
            let b = fp.bounds
            let w = max(b.maxX - b.minX, 0.1)
            let h = max(b.maxY - b.minY, 0.1)
            let margin: CGFloat = 24
            let scale = min((size.width - margin * 2) / CGFloat(w),
                            (size.height - margin * 2) / CGFloat(h))
            let originX = (size.width - CGFloat(w) * scale) / 2
            let originY = (size.height - CGFloat(h) * scale) / 2
            let map: (FPPoint) -> CGPoint = { p in
                CGPoint(x: originX + CGFloat(p.x - b.minX) * scale,
                        y: originY + CGFloat(p.y - b.minY) * scale)
            }
            // Graphics first (courtyard/fab under silk under pads).
            for graphic in fp.graphics {
                drawGraphic(graphic, in: ctx, map: map, scale: scale)
            }
            for pad in fp.pads {
                drawPad(pad, in: ctx, map: map, scale: scale)
            }
        }
    }

    private func layerColor(_ layer: String) -> Color {
        if layer.contains("CrtYd") { return Color.white.opacity(0.28) }
        if layer.contains("SilkS") { return Color(red: 0.95, green: 0.9, blue: 0.6) }
        if layer.contains("Fab") { return Color.gray.opacity(0.8) }
        if layer.contains("Mask") { return Color.purple.opacity(0.6) }
        if layer.contains("Paste") { return Color.white.opacity(0.55) }
        if layer.contains("Cu") { return Color.orange }
        return Color.white.opacity(0.6)
    }

    private func drawGraphic(_ graphic: KiCadFootprintGraphic,
                             in ctx: GraphicsContext,
                             map: (FPPoint) -> CGPoint,
                             scale: CGFloat) {
        let color = layerColor(graphic.layer)
        let lineWidth = max(1, CGFloat(0.12) * scale)
        switch graphic {
        case .line(let a, let b, _, _, _, _):
            var path = Path()
            path.move(to: map(a))
            path.addLine(to: map(b))
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .rect(let a, let b, _, _, _, let fill):
            let rect = CGRect(x: min(map(a).x, map(b).x), y: min(map(a).y, map(b).y),
                              width: abs(map(b).x - map(a).x), height: abs(map(b).y - map(a).y))
            let path = Path(rect)
            if fill == "solid" { ctx.fill(path, with: .color(color.opacity(0.25))) }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .circle(let center, let radius, _, _, _, let fill):
            let c = map(center)
            let r = CGFloat(radius) * scale
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            let path = Path(ellipseIn: rect)
            if fill == "solid" { ctx.fill(path, with: .color(color.opacity(0.25))) }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .arc(let a, let m, let b, _, _, _, _):
            let points = arcSamplePoints(a: a, m: m, e: b)
            var path = Path()
            for (i, point) in points.enumerated() {
                if i == 0 { path.move(to: map(point)) } else { path.addLine(to: map(point)) }
            }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .poly(let points, _, _, _, let fill):
            guard points.count >= 2 else { return }
            var path = Path()
            for (i, point) in points.enumerated() {
                if i == 0 { path.move(to: map(point)) } else { path.addLine(to: map(point)) }
            }
            path.closeSubpath()
            if fill == "solid" { ctx.fill(path, with: .color(color.opacity(0.25))) }
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .curve(let p1, let p2, let p3, let p4, _, _, _, _):
            var path = Path()
            path.move(to: map(p1))
            path.addCurve(to: map(p4), control1: map(p2), control2: map(p3))
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        case .text(let text):
            guard !text.hidden, !text.text.isEmpty else { return }
            let fontSize = max(7, CGFloat(text.size) * scale)
            ctx.draw(Text(text.text)
                .font(.system(size: fontSize))
                .foregroundColor(color),
                     at: map(FPPoint(x: text.x, y: text.y)), anchor: .center)
        }
    }

    private func drawPad(_ pad: KiCadFootprintPad,
                         in ctx: GraphicsContext,
                         map: (FPPoint) -> CGPoint,
                         scale: CGFloat) {
        var pctx = ctx
        let center = map(pad.center)
        pctx.translateBy(x: center.x, y: center.y)
        pctx.rotate(by: .degrees(pad.rotation))

        let color = padColor(pad)
        let w = CGFloat(pad.width) * scale
        let h = CGFloat(pad.height) * scale
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)

        switch pad.shape {
        case .circle, .oval:
            pctx.fill(Path(ellipseIn: rect), with: .color(color))
        case .roundrect:
            let ratio = CGFloat(pad.roundrectRatio ?? 0.25)
            let radius = min(w, h) / 2 * min(max(ratio, 0), 0.5) * 2
            pctx.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(color))
        case .trapezoid:
            let dx = CGFloat(pad.rectDelta?.x ?? 0) * scale
            let dy = CGFloat(pad.rectDelta?.y ?? 0) * scale
            var path = Path()
            // Approximation of KiCad's rect_delta trapezoid: the delta
            // insets the two corners of one side.
            if abs(dx) >= abs(dy) {
                path.move(to: CGPoint(x: -w / 2 + dx / 2, y: -h / 2))
                path.addLine(to: CGPoint(x: w / 2 - dx / 2, y: -h / 2))
                path.addLine(to: CGPoint(x: w / 2, y: h / 2))
                path.addLine(to: CGPoint(x: -w / 2, y: h / 2))
            } else {
                path.move(to: CGPoint(x: -w / 2, y: -h / 2 + dy / 2))
                path.addLine(to: CGPoint(x: w / 2, y: -h / 2))
                path.addLine(to: CGPoint(x: w / 2, y: h / 2))
                path.addLine(to: CGPoint(x: -w / 2, y: h / 2 - dy / 2))
            }
            path.closeSubpath()
            pctx.fill(path, with: .color(color))
        case .custom:
            // Draw the pad's primitives in pad-local coordinates.
            for primitive in pad.primitives {
                drawGraphic(primitive, in: pctx,
                            map: { p in CGPoint(x: CGFloat(p.x) * scale, y: CGFloat(p.y) * scale) },
                            scale: scale)
            }
            // Fall back to a faint anchor outline so a custom pad with
            // no fillable primitives is still visible.
            pctx.stroke(Path(rect), with: .color(color.opacity(0.5)), lineWidth: 1)
        case .rect:
            pctx.fill(Path(rect), with: .color(color))
        }

        if let drill = pad.drill {
            let dw = CGFloat(drill.width) * scale
            let dh = CGFloat(drill.height) * scale
            let drillRect = CGRect(
                x: CGFloat(drill.offsetX) * scale - dw / 2,
                y: CGFloat(drill.offsetY) * scale - dh / 2,
                width: dw, height: dh)
            pctx.fill(Path(ellipseIn: drillRect), with: .color(Color(white: 0.08)))
            pctx.stroke(Path(ellipseIn: drillRect), with: .color(.white.opacity(0.5)), lineWidth: 1)
        }

        if !pad.number.isEmpty {
            let fontSize = max(7, min(w, h) * 0.55)
            pctx.draw(Text(pad.number)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(.black.opacity(0.75)),
                      at: CGPoint(x: 0, y: 0), anchor: .center)
        }
    }

    private func padColor(_ pad: KiCadFootprintPad) -> Color {
        if pad.type == .npThruHole { return Color.gray.opacity(0.8) }
        let hasFront = pad.layers.contains { $0.hasPrefix("F.") || $0 == "*.Cu" }
        let hasBack = pad.layers.contains { $0.hasPrefix("B.") || $0 == "*.Cu" }
        if pad.isThroughHole { return Color(red: 0.85, green: 0.55, blue: 0.2) }
        if hasFront && hasBack { return Color(red: 0.8, green: 0.4, blue: 0.7) }
        if hasBack && !hasFront { return Color(red: 0.3, green: 0.5, blue: 0.9) }
        return Color(red: 0.9, green: 0.45, blue: 0.25)
    }

    /// Samples the arc through three file points via the circumcenter,
    /// along the sweep passing through the mid point (same approach as
    /// the symbol draw list, in y-down file coordinates).
    private func arcSamplePoints(a: FPPoint, m: FPPoint, e: FPPoint) -> [FPPoint] {
        var points: [FPPoint] = [a]
        let d = 2 * (a.x * (m.y - e.y) + m.x * (e.y - a.y) + e.x * (a.y - m.y))
        if abs(d) < 1e-9 {
            points.append(m)
            points.append(e)
            return points
        }
        let aSq = a.x * a.x + a.y * a.y
        let mSq = m.x * m.x + m.y * m.y
        let eSq = e.x * e.x + e.y * e.y
        let cx = (aSq * (m.y - e.y) + mSq * (e.y - a.y) + eSq * (a.y - m.y)) / d
        let cy = (aSq * (e.x - m.x) + mSq * (a.x - e.x) + eSq * (m.x - a.x)) / d
        let r = hypot(a.x - cx, a.y - cy)
        let a0 = atan2(a.y - cy, a.x - cx)
        let am = atan2(m.y - cy, m.x - cx)
        let a1 = atan2(e.y - cy, e.x - cx)
        func norm(_ v: Double) -> Double {
            var v = v.truncatingRemainder(dividingBy: 2 * Double.pi)
            if v < 0 { v += 2 * Double.pi }
            return v
        }
        let sweepPos = norm(a1 - a0)
        let midPos = norm(am - a0)
        let sweep = midPos <= sweepPos + 1e-9 ? sweepPos : -(2 * Double.pi - sweepPos)
        let steps = max(4, Int(abs(sweep) / (Double.pi / 36)) + 1)
        for i in 1...steps {
            let t = a0 + sweep * Double(i) / Double(steps)
            points.append(FPPoint(x: cx + r * cos(t), y: cy + r * sin(t)))
        }
        return points
    }
}
