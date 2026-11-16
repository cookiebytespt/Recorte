import AppKit
import CutterCore
import SwiftUI

/// The drawing canvas: shows the project, handles tools, selection, handles and panning.
struct CanvasView: View {
    @Bindable var editor: EditorState

    @State private var drag: DragState?
    @State private var baseZoom: CGFloat = 1
    /// Last click on an object, to recognise double-clicks (which start point editing).
    @State private var lastClick: (id: UUID, time: Date)?
    /// Last click on a node while editing points (double-click toggles smooth / corner).
    @State private var lastNodeClick: (path: Int, point: Int, time: Date)?
    @FocusState private var focused: Bool

    private let margin: CGFloat = 60
    private let handleSize: CGFloat = 8

    enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var unit: (x: Double, y: Double) {
            switch self {
            case .topLeft: (0, 0)
            case .top: (0.5, 0)
            case .topRight: (1, 0)
            case .right: (1, 0.5)
            case .bottomRight: (1, 1)
            case .bottom: (0.5, 1)
            case .bottomLeft: (0, 1)
            case .left: (0, 0.5)
            }
        }
    }

    struct DragState {
        enum Kind { case select, move, resize(Handle), create, freehand, pan, marquee, editPoint(path: Int, point: Int), editPath(Int),
                  editHandle(path: Int, point: Int, out: Bool, keepSmooth: Bool), pullHandles(path: Int, point: Int) }
        var kind: Kind
        var startMM: Point
        var currentMM: Point
        var startPan: CGSize
        var originalFrames: [UUID: Rect] = [:]
        var originalObject: DesignObject?
        var createdID: UUID?
        var freehandPoints: [Point] = []
        var moved = false
    }

    struct Viewport {
        var scale: CGFloat
        var origin: CGPoint

        func toView(_ p: Point) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
        func toMM(_ v: CGPoint) -> Point { Point(Double((v.x - origin.x) / scale), Double((v.y - origin.y) / scale)) }
    }

    var body: some View {
        GeometryReader { geo in
            let vp = viewport(for: geo.size)
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                Canvas { ctx, _ in draw(in: &ctx, vp: vp) }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(vp))
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { v in editor.zoom = min(max(baseZoom * v.magnification, 0.1), 40) }
                            .onEnded { _ in baseZoom = editor.zoom }
                    )
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handleKey(press) }
            .onDeleteCommand { editor.deleteSelection() }
            .onMoveCommand { direction in
                switch direction {
                case .up: editor.nudge(0, -1)
                case .down: editor.nudge(0, 1)
                case .left: editor.nudge(-1, 0)
                case .right: editor.nudge(1, 0)
                @unknown default: break
                }
            }
            .overlay(alignment: .bottomLeading) { zoomBar }
            .overlay(alignment: .top) { if editor.pathEdit != nil { pathEditHint } }
            .onAppear { focused = true }
        }
    }

    // MARK: Viewport

    private func viewport(for size: CGSize) -> Viewport {
        let canvas = editor.design.canvasSize
        let fit = min((size.width - margin * 2) / max(canvas.width, 1), (size.height - margin * 2) / max(canvas.height, 1))
        let scale = max(fit, 0.01) * editor.zoom
        let origin = CGPoint(
            x: (size.width - canvas.width * scale) / 2 + editor.pan.width,
            y: (size.height - canvas.height * scale) / 2 + editor.pan.height
        )
        return Viewport(scale: scale, origin: origin)
    }

    private var zoomBar: some View {
        HStack(spacing: 8) {
            Button { setZoom(editor.zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int((editor.zoom * 100).rounded())) %")
                .monospacedDigit()
                .frame(width: 48)
            Button { setZoom(editor.zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            Button("Fit") { setZoom(1); editor.pan = .zero }
            Divider().frame(height: 14)
            Text("\(editor.design.canvasSize.width.formatted(.number.precision(.fractionLength(0)))) × \(editor.design.canvasSize.height.formatted(.number.precision(.fractionLength(0)))) mm")
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    private var pathEditHint: some View {
        HStack(spacing: 10) {
            Text("Editing points").fontWeight(.semibold)
            Text("Click a line to select it · drag points, handles or lines · ⌥-click the line to add a point · ⌥-drag a point to pull out curve handles · double-click a point for smooth/corner · ⌫ deletes")
                .foregroundStyle(.secondary)
            Button("Done") { editor.endPathEdit() }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    private func setZoom(_ z: CGFloat) {
        editor.zoom = min(max(z, 0.1), 40)
        baseZoom = editor.zoom
    }

    // MARK: Drawing

    private func draw(in ctx: inout GraphicsContext, vp: Viewport) {
        let design = editor.design
        let canvasRect = CGRect(origin: vp.origin, size: CGSize(width: design.canvasSize.width * vp.scale, height: design.canvasSize.height * vp.scale))
        ctx.fill(Path(canvasRect.offsetBy(dx: 2, dy: 3)), with: .color(.black.opacity(0.15)))
        ctx.fill(Path(canvasRect), with: .color(.white))

        // Grid every 10 mm when readable.
        if vp.scale * 10 >= 8 {
            var grid = Path()
            var x = 0.0
            while x <= design.canvasSize.width {
                grid.move(to: vp.toView(Point(x, 0))); grid.addLine(to: vp.toView(Point(x, design.canvasSize.height))); x += 10
            }
            var y = 0.0
            while y <= design.canvasSize.height {
                grid.move(to: vp.toView(Point(0, y))); grid.addLine(to: vp.toView(Point(design.canvasSize.width, y))); y += 10
            }
            ctx.stroke(grid, with: .color(.gray.opacity(0.12)), lineWidth: 1)
        }
        ctx.stroke(Path(canvasRect), with: .color(.gray.opacity(0.6)), lineWidth: 1)

        // Printed artwork first (it sits under the cut lines).
        for object in design.objects where object.isVisible && object.kind.isImage {
            guard let image = editor.image(for: object) else { continue }
            let c = vp.toView(object.center)
            let w = object.frame.width * vp.scale, h = object.frame.height * vp.scale
            ctx.drawLayer { layer in
                layer.translateBy(x: c.x, y: c.y)
                layer.rotate(by: .degrees(object.rotation))
                layer.draw(Image(nsImage: image), in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            }
        }

        // Registration marks and the safe area for Print & Cut sheets.
        if design.printAndCut.isEnabled {
            let sheet = design.printSheet
            let d = sheet.markDiameterMM * vp.scale
            for m in sheet.markCenters {
                let c = vp.toView(m)
                let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
                if sheet.layout.printsMarks {
                    ctx.fill(Path(ellipseIn: r), with: .color(sheet.marksFitPage ? .black : .red))
                } else {
                    ctx.stroke(Path(ellipseIn: r), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            let safe = sheet.safeArea
            let r = CGRect(p1: vp.toView(safe.origin), p2: vp.toView(Point(safe.maxX, safe.maxY)))
            ctx.stroke(Path(r), with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        }

        let tolerance = max(0.03, 0.4 / Double(vp.scale))
        for object in design.objects where object.isVisible && !object.kind.isImage {
            let selected = editor.selection.contains(object.id)
            var closedPath = Path(), openPath = Path()
            for poly in object.outlines(tolerance: tolerance) {
                guard let first = poly.points.first else { continue }
                var p = Path()
                p.move(to: vp.toView(first))
                for pt in poly.points.dropFirst() { p.addLine(to: vp.toView(pt)) }
                if poly.isClosed { p.closeSubpath(); closedPath.addPath(p) } else { openPath.addPath(p) }
            }
            // The canvas is always white, so use fixed ink colours rather than the appearance's primary colour.
            if object.kind.isText { ctx.fill(closedPath, with: .color(.black.opacity(0.15)), style: FillStyle(eoFill: true)) }
            else { ctx.fill(closedPath, with: .color(.accentColor.opacity(0.08)), style: FillStyle(eoFill: true)) }
            let ink = Color(red: 0.12, green: 0.12, blue: 0.14)
            let stroke: Color = object.isLocked ? .gray : (selected ? .accentColor : ink)
            ctx.stroke(closedPath, with: .color(stroke), lineWidth: selected ? 1.5 : 1)
            ctx.stroke(openPath, with: .color(stroke), lineWidth: selected ? 1.5 : 1)
        }

        // Selection boxes and handles.
        let editing = editor.pathEditObject
        for object in editor.selectedObjects where object.id != editing?.id {
            let corners = [Point(0, 0), Point(object.frame.width, 0), Point(object.frame.width, object.frame.height), Point(0, object.frame.height)]
                .map { vp.toView(object.localToDocument.apply($0)) }
            var box = Path()
            box.move(to: corners[0]); for c in corners.dropFirst() { box.addLine(to: c) }; box.closeSubpath()
            ctx.stroke(box, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: editor.selection.count > 1 ? [4, 3] : []))
        }
        if let object = editor.singleSelection, !object.isLocked, object.id != editing?.id {
            for handle in Handle.allCases {
                let c = handlePosition(handle, of: object, vp: vp)
                let r = CGRect(x: c.x - handleSize / 2, y: c.y - handleSize / 2, width: handleSize, height: handleSize)
                ctx.fill(Path(r), with: .color(.white))
                ctx.stroke(Path(r), with: .color(.accentColor), lineWidth: 1)
            }
        }

        if let editing, let edit = editor.validPathEdit {
            drawPathEdit(in: &ctx, object: editing, edit: edit, vp: vp)
        }

        // In-progress feedback.
        if let drag {
            switch drag.kind {
            case .marquee:
                let r = CGRect(p1: vp.toView(drag.startMM), p2: vp.toView(drag.currentMM))
                ctx.fill(Path(r), with: .color(.accentColor.opacity(0.08)))
                ctx.stroke(Path(r), with: .color(.accentColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            case .freehand:
                var p = Path()
                for (i, pt) in drag.freehandPoints.enumerated() {
                    if i == 0 { p.move(to: vp.toView(pt)) } else { p.addLine(to: vp.toView(pt)) }
                }
                ctx.stroke(p, with: .color(.accentColor), lineWidth: 1.5)
            default:
                break
            }
        }
    }

    /// Nodes whose handles are shown: the selected node and its neighbours.
    private func visibleHandleNodes(_ curve: BezierPath, selected k: Int?) -> [Int] {
        guard let k, curve.nodes.indices.contains(k) else { return [] }
        let n = curve.nodes.count
        var out = [k]
        if k > 0 || curve.isClosed { out.append((k - 1 + n) % n) }
        if k < n - 1 || curve.isClosed { out.append((k + 1) % n) }
        return Array(Set(out))
    }

    /// Handles of node `k` that shape a segment (open lines have no handle before the first node or after the last).
    private func usedHandles(_ curve: BezierPath, _ k: Int) -> [(out: Bool, point: Point)] {
        let node = curve.nodes[k]
        var r: [(Bool, Point)] = []
        if let h = node.handleIn, k > 0 || curve.isClosed { r.append((false, h)) }
        if let h = node.handleOut, k < curve.nodes.count - 1 || curve.isClosed { r.append((true, h)) }
        return r
    }

    /// Point editing: every line of the object, the selected one highlighted with its nodes and handles.
    private func drawPathEdit(in ctx: inout GraphicsContext, object: DesignObject, edit: PathEdit, vp: Viewport) {
        let lines = object.outlines(tolerance: max(0.03, 0.4 / Double(vp.scale)))
        for (i, line) in lines.enumerated() {
            guard let first = line.points.first else { continue }
            var p = Path()
            p.move(to: vp.toView(first))
            for pt in line.points.dropFirst() { p.addLine(to: vp.toView(pt)) }
            if line.isClosed { p.closeSubpath() }
            let selected = i == edit.path
            ctx.stroke(p, with: .color(selected ? .accentColor : .accentColor.opacity(0.55)), lineWidth: selected ? 2.5 : 1.5)
        }
        guard let p = edit.path, let curves = object.artworkLocalCurves, curves.indices.contains(p) else { return }
        let t = object.localToDocument
        let curve = curves[p]
        // Handles first so the nodes sit on top.
        for k in visibleHandleNodes(curve, selected: edit.point) {
            let anchor = vp.toView(t.apply(curve.nodes[k].point))
            for h in usedHandles(curve, k) {
                let c = vp.toView(t.apply(h.point))
                var line = Path()
                line.move(to: anchor); line.addLine(to: c)
                ctx.stroke(line, with: .color(.accentColor), lineWidth: 1)
                let r = CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)
                ctx.fill(Path(ellipseIn: r), with: .color(.accentColor))
            }
        }
        let s: CGFloat = 6
        for (k, node) in curve.nodes.enumerated() {
            let c = vp.toView(t.apply(node.point))
            let size = k == edit.point ? s + 2 : s
            let r = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
            let shape = node.isSmooth ? Path(ellipseIn: r) : Path(r)   // circle = smooth, square = corner
            ctx.fill(shape, with: .color(k == edit.point ? .accentColor : .white))
            ctx.stroke(shape, with: .color(.accentColor), lineWidth: 1)
        }
    }

    /// Mouse-down while editing points. Returns `nil` when the click is outside the edited object.
    private func beginPathEditDrag(at mm: Point, vp: Viewport) -> DragState.Kind? {
        guard let edit = editor.validPathEdit, let object = editor.pathEditObject,
              let curves = object.artworkLocalCurves, let inv = object.localToDocument.inverted() else { return nil }
        let local = inv.apply(mm)
        let tolerance = Double(handleSize) / Double(vp.scale)
        let option = NSEvent.modifierFlags.contains(.option)
        let id = object.id

        if let p = edit.path {
            let curve = curves[p]
            // A handle of the selected node or its neighbours.
            var bestHandle: (k: Int, out: Bool, d: Double)?
            for k in visibleHandleNodes(curve, selected: edit.point) {
                for h in usedHandles(curve, k) {
                    let d = h.point.distance(to: local)
                    if d <= tolerance, bestHandle == nil || d < bestHandle!.d { bestHandle = (k, h.out, d) }
                }
            }
            if let h = bestHandle {
                editor.pathEdit = PathEdit(objectID: id, path: p, point: h.k)
                return .editHandle(path: p, point: h.k, out: h.out, keepSmooth: curve.nodes[h.k].isSmooth && !option)
            }
            // A node of the selected line.
            var best: (index: Int, distance: Double)?
            for (k, node) in curve.nodes.enumerated() {
                let d = node.point.distance(to: local)
                if d <= tolerance, best == nil || d < best!.distance { best = (k, d) }
            }
            if let k = best?.index {
                editor.pathEdit = PathEdit(objectID: id, path: p, point: k)
                let now = Date()
                if let last = lastNodeClick, last.path == p, last.point == k,
                   now.timeIntervalSince(last.time) < NSEvent.doubleClickInterval {
                    lastNodeClick = nil
                    editor.setSelectedPoint(smooth: !curve.nodes[k].hasHandles)
                    return .select
                }
                lastNodeClick = (p, k, now)
                return option ? .pullHandles(path: p, point: k) : .editPoint(path: p, point: k)
            }
        }

        // A line: the selected one first, then the nearest.
        var hit: (path: Int, segment: Int, t: Double)?
        if let p = edit.path, let s = curves[p].nearestSegment(to: local), s.distance <= tolerance {
            hit = (p, s.index, s.t)
        } else {
            var bestDistance = tolerance
            for (i, curve) in curves.enumerated() {
                if let s = curve.nearestSegment(to: local), s.distance <= bestDistance {
                    bestDistance = s.distance
                    hit = (i, s.index, s.t)
                }
            }
        }
        if let hit {
            if option, hit.path == edit.path {
                var updated = object
                if let k = updated.insertArtworkPoint(path: hit.path, segment: hit.segment, at: hit.t) {
                    editor.change { $0.update(id) { $0 = updated } }
                    editor.pathEdit = PathEdit(objectID: id, path: hit.path, point: k)
                    return .editPoint(path: hit.path, point: k)
                }
            }
            editor.pathEdit = PathEdit(objectID: id, path: hit.path, point: nil)
            return .editPath(hit.path)
        }

        // Inside the object but off its lines: keep editing, clear the line selection.
        let box = Rect(minX: 0, minY: 0, maxX: object.frame.width, maxY: object.frame.height).insetBy(-tolerance)
        if box.contains(local) {
            editor.pathEdit = PathEdit(objectID: id, path: curves.count == 1 ? 0 : nil, point: nil)
            return .select
        }
        return nil
    }

    /// Starts a point-editing drag of `kind` (from `beginPathEditDrag`).
    private func startPathEditDrag(_ kind: DragState.Kind, state: inout DragState) {
        state.kind = kind
        if case .select = kind { return }
        state.originalObject = editor.pathEditObject
        editor.beginTransaction()
    }

    /// Live update of a point-editing drag: applies `body` to the original lines (frame-local mm).
    private func dragEdit(_ d: DragState, delta: Point, _ body: (inout [BezierPath], Point) -> Void) {
        guard d.moved, let original = d.originalObject, let inv = original.localToDocument.inverted() else { return }
        let move = inv.applyVector(delta)
        var updated = original
        updated.editArtworkCurves { body(&$0, move) }
        editor.changeLive { $0.update(original.id) { $0 = updated } }
    }

    private func handlePosition(_ handle: Handle, of object: DesignObject, vp: Viewport) -> CGPoint {
        let u = handle.unit
        return vp.toView(object.localToDocument.apply(Point(u.x * object.frame.width, u.y * object.frame.height)))
    }

    // MARK: Gestures

    private func dragGesture(_ vp: Viewport) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                focused = true
                let mm = vp.toMM(value.location)
                if drag == nil {
                    drag = begin(at: vp.toMM(value.startLocation), view: value.startLocation, vp: vp)
                }
                guard var d = drag else { return }
                d.currentMM = mm
                if value.translation.width.magnitude > 2 || value.translation.height.magnitude > 2 { d.moved = true }
                update(&d, translation: value.translation, vp: vp)
                drag = d
            }
            .onEnded { value in
                guard var d = drag else { return }
                d.currentMM = vp.toMM(value.location)
                finish(d, vp: vp)
                drag = nil
            }
    }

    private func begin(at mm: Point, view: CGPoint, vp: Viewport) -> DragState {
        let shift = NSEvent.modifierFlags.contains(.shift)
        var state = DragState(kind: .select, startMM: mm, currentMM: mm, startPan: editor.pan)

        switch editor.tool {
        case .hand:
            state.kind = .pan
        case .select:
            if editor.pathEdit != nil {
                if let kind = beginPathEditDrag(at: mm, vp: vp) {
                    startPathEditDrag(kind, state: &state)
                    return state
                }
                editor.endPathEdit()
            }
            if let object = editor.singleSelection, !object.isLocked {
                for handle in Handle.allCases {
                    let c = handlePosition(handle, of: object, vp: vp)
                    if hypot(c.x - view.x, c.y - view.y) <= handleSize {
                        state.kind = .resize(handle)
                        state.originalObject = object
                        editor.beginTransaction()
                        return state
                    }
                }
            }
            let tolerance = max(1.0, 4.0 / Double(vp.scale))
            if let hit = editor.design.objects.reversed().first(where: { $0.isVisible && $0.hitTest(mm, tolerance: tolerance) }) {
                // Double-click on artwork or a cut contour: edit its lines and points.
                let now = Date()
                if !shift, hit.isEditableArtwork, !hit.isLocked, let last = lastClick, last.id == hit.id,
                   now.timeIntervalSince(last.time) < NSEvent.doubleClickInterval {
                    lastClick = nil
                    editor.beginPathEdit(hit.id)
                    startPathEditDrag(beginPathEditDrag(at: mm, vp: vp) ?? .select, state: &state)
                    return state
                }
                lastClick = (hit.id, now)
                if shift {
                    if editor.selection.contains(hit.id) { editor.selection.remove(hit.id) } else { editor.selection.insert(hit.id) }
                } else if !editor.selection.contains(hit.id) {
                    editor.selection = [hit.id]
                }
                state.kind = .move
                state.originalFrames = Dictionary(uniqueKeysWithValues: editor.selectedObjects.filter { !$0.isLocked }.map { ($0.id, $0.frame) })
                editor.beginTransaction()
            } else {
                if !shift { editor.selection = [] }
                state.kind = .marquee
            }
        case .freehand:
            state.kind = .freehand
            state.freehandPoints = [mm]
        case .text:
            state.kind = .select
        case .rectangle, .ellipse, .line, .polygon, .star:
            state.kind = .create
            editor.beginTransaction()
            let kind: ShapeKind
            let name: String
            switch editor.tool {
            case .rectangle: kind = .rectangle(cornerRadius: 0); name = String(localized: "Rectangle")
            case .ellipse: kind = .ellipse; name = String(localized: "Ellipse")
            case .line: kind = .line(reversed: false); name = String(localized: "Line")
            case .polygon: kind = .polygon(sides: 6); name = String(localized: "Polygon")
            default: kind = .star(points: 5, innerRatio: 0.5); name = String(localized: "Star")
            }
            let object = DesignObject(name: name, kind: kind, frame: Rect(origin: mm, size: Size(0, 0)))
            editor.changeLive { $0.objects.append(object) }
            editor.selection = [object.id]
            state.createdID = object.id
        }
        return state
    }

    private func update(_ d: inout DragState, translation: CGSize, vp: Viewport) {
        let delta = Point(Double(translation.width / vp.scale), Double(translation.height / vp.scale))
        switch d.kind {
        case .pan:
            editor.pan = CGSize(width: d.startPan.width + translation.width, height: d.startPan.height + translation.height)
        case .move:
            guard d.moved else { return }
            let frames = d.originalFrames
            editor.changeLive { doc in
                for i in doc.objects.indices {
                    if let f = frames[doc.objects[i].id] {
                        doc.objects[i].frame = Rect(origin: f.origin + delta, size: f.size)
                    }
                }
            }
        case .resize(let handle):
            guard let original = d.originalObject, let inv = original.localToDocument.inverted() else { return }
            let lp = inv.apply(d.currentMM)
            var minX = 0.0, minY = 0.0, maxX = original.frame.width, maxY = original.frame.height
            let u = handle.unit
            if u.x == 0 { minX = lp.x } else if u.x == 1 { maxX = lp.x }
            if u.y == 0 { minY = lp.y } else if u.y == 1 { maxY = lp.y }
            if NSEvent.modifierFlags.contains(.shift), original.frame.width > 0, original.frame.height > 0, u.x != 0.5, u.y != 0.5 {
                let aspect = original.frame.width / original.frame.height
                let w = abs(maxX - minX)
                let h = w / aspect
                if u.y == 0 { minY = maxY - h } else { maxY = minY + h }
            }
            let w = max(abs(maxX - minX), 0.5), h = max(abs(maxY - minY), 0.5)
            let center = original.localToDocument.apply(Point((minX + maxX) / 2, (minY + maxY) / 2))
            let frame = Rect(minX: center.x - w / 2, minY: center.y - h / 2, maxX: center.x + w / 2, maxY: center.y + h / 2)
            let id = original.id
            editor.changeLive { $0.update(id) { $0.frame = frame } }
        case .create:
            guard let id = d.createdID else { return }
            var frame = Rect.from(d.startMM, d.currentMM)
            let shift = NSEvent.modifierFlags.contains(.shift)
            if shift {
                let s = max(frame.width, frame.height)
                frame = Rect(minX: d.currentMM.x < d.startMM.x ? d.startMM.x - s : d.startMM.x,
                             minY: d.currentMM.y < d.startMM.y ? d.startMM.y - s : d.startMM.y,
                             maxX: d.currentMM.x < d.startMM.x ? d.startMM.x : d.startMM.x + s,
                             maxY: d.currentMM.y < d.startMM.y ? d.startMM.y : d.startMM.y + s)
            }
            let reversed = (d.currentMM.x - d.startMM.x) * (d.currentMM.y - d.startMM.y) < 0
            editor.changeLive { doc in
                doc.update(id) { obj in
                    obj.frame = frame
                    if case .line = obj.kind { obj.kind = .line(reversed: reversed) }
                }
            }
        case .freehand:
            if let last = d.freehandPoints.last, last.distance(to: d.currentMM) >= 0.3 / Double(vp.scale) * 2 {
                d.freehandPoints.append(d.currentMM)
            }
        case .editPoint(let p, let k):
            dragEdit(d, delta: delta) { curves, move in
                guard curves.indices.contains(p), curves[p].nodes.indices.contains(k) else { return }
                curves[p].nodes[k] = curves[p].nodes[k].moved(by: move)
            }
        case .editPath(let p):
            dragEdit(d, delta: delta) { curves, move in
                guard curves.indices.contains(p) else { return }
                curves[p].nodes = curves[p].nodes.map { $0.moved(by: move) }
            }
        case .editHandle(let p, let k, let out, let keepSmooth):
            dragEdit(d, delta: delta) { curves, move in
                guard curves.indices.contains(p), curves[p].nodes.indices.contains(k),
                      let start = out ? curves[p].nodes[k].handleOut : curves[p].nodes[k].handleIn else { return }
                curves[p].moveHandle(of: k, out: out, to: start + move, keepSmooth: keepSmooth)
            }
        case .pullHandles(let p, let k):
            dragEdit(d, delta: delta) { curves, move in
                guard curves.indices.contains(p), curves[p].nodes.indices.contains(k) else { return }
                let curve = curves[p]
                let anchor = curve.nodes[k].point
                // Symmetric handles: dragging sets the outgoing one, the incoming one mirrors it.
                curves[p].nodes[k].handleOut = (k < curve.nodes.count - 1 || curve.isClosed) ? anchor + move : nil
                curves[p].nodes[k].handleIn = (k > 0 || curve.isClosed) ? anchor - move : nil
            }
        case .select, .marquee:
            break
        }
    }

    private func finish(_ d: DragState, vp: Viewport) {
        switch d.kind {
        case .move, .resize, .editPoint, .editPath, .editHandle, .pullHandles:
            editor.endTransaction()
        case .create:
            guard let id = d.createdID else { return }
            if !d.moved {
                let s = 40.0
                editor.changeLive { $0.update(id) { $0.frame = Rect(origin: d.startMM - Point(s / 2, s / 2), size: Size(s, s)) } }
            }
            editor.endTransaction()
            editor.tool = .select
        case .freehand:
            let pts = d.freehandPoints
            let b = pts.reduce(Rect.null) { $0.including($1) }
            guard pts.count >= 2, !b.isNull else { return }
            let w = max(b.width, 0.5), h = max(b.height, 0.5)
            let normalized = pts.map { Point(($0.x - b.minX) / w, ($0.y - b.minY) / h) }
            let closed = pts.count > 3 && pts.first!.distance(to: pts.last!) < 3 / Double(vp.scale) * 2
            editor.add(.freehand(points: normalized, closed: closed),
                       frame: Rect(minX: b.minX, minY: b.minY, maxX: b.minX + w, maxY: b.minY + h),
                       name: String(localized: "Drawing"))
        case .marquee:
            guard d.moved else { return }
            let r = Rect.from(d.startMM, d.currentMM)
            let hits = editor.design.objects.filter { obj in
                guard obj.isVisible else { return false }
                let b = obj.outlines(tolerance: 0.5).bounds
                return !b.isNull && b.minX >= r.minX && b.maxX <= r.maxX && b.minY >= r.minY && b.maxY <= r.maxY
            }
            editor.selection.formUnion(hits.map(\.id))
        case .select:
            if editor.tool == .text, !d.moved {
                let spec = TextSpec(text: String(localized: "Text"))
                let size = DesignObject.naturalTextSize(spec)
                editor.add(.text(spec), frame: Rect(origin: d.startMM, size: size), name: String(localized: "Text"))
                editor.tool = .select
            }
        case .pan:
            break
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape, var edit = editor.pathEdit {
            if edit.point != nil { edit.point = nil; editor.pathEdit = edit } else { editor.endPathEdit() }
            return .handled
        }
        if press.key == .return, press.modifiers.isEmpty {
            if editor.pathEdit != nil { editor.endPathEdit(); return .handled }
            if editor.canEditPoints, let id = editor.singleSelection?.id { editor.beginPathEdit(id); return .handled }
        }
        if press.key == .escape {
            if editor.tool != .select { editor.tool = .select } else { editor.selection = [] }
            return .handled
        }
        if press.modifiers.contains(.command) {
            switch press.characters {
            case "a": editor.selectAll(); return .handled
            case "d": editor.duplicateSelection(); return .handled
            default: return .ignored
            }
        }
        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        if let tool = Tool.allCases.first(where: { String($0.shortcut) == press.characters.lowercased() }) {
            editor.tool = tool
            return .handled
        }
        return .ignored
    }
}

extension Rect {
    static func from(_ a: Point, _ b: Point) -> Rect {
        Rect(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
    }
}

extension CGRect {
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }
}
