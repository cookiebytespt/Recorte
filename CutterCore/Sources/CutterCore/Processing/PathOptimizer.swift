import Foundation

/// Orders polylines to reduce travel moves, cutting shapes that lie inside other
/// shapes first so the surrounding vinyl stays attached while the inner parts are cut.
public struct PathOptimizer: Sendable {
    public var innerFirst: Bool
    /// Closed shapes may start at any vertex; open ones may be reversed.
    public var allowStartChange: Bool

    public init(innerFirst: Bool = true, allowStartChange: Bool = true) {
        self.innerFirst = innerFirst
        self.allowStartChange = allowStartChange
    }

    public func optimize(_ input: [Polyline], startingAt origin: Point = .zero) -> [Polyline] {
        let paths = input.filter { !$0.isEmpty }
        guard !paths.isEmpty else { return paths }

        // children[j] = indices of paths contained in path j.
        var children = [Set<Int>](repeating: [], count: paths.count)
        if innerFirst {
            let bounds = paths.map(\.bounds)
            for j in paths.indices where paths[j].isClosed {
                for i in paths.indices where i != j {
                    guard bounds[j].contains(bounds[i]), let p = paths[i].start, paths[j].contains(p) else { continue }
                    children[j].insert(i)
                }
            }
        }

        var done = [Bool](repeating: false, count: paths.count)
        var result: [Polyline] = []
        result.reserveCapacity(paths.count)
        var position = origin

        for _ in paths.indices {
            var best: (index: Int, path: Polyline, distance: Double)? = nil
            for i in paths.indices where !done[i] {
                if innerFirst, children[i].contains(where: { !done[$0] }) { continue }
                let candidate = bestOrientation(of: paths[i], from: position)
                let d = candidate.start.map { position.distance(to: $0) } ?? .infinity
                if best == nil || d < best!.distance { best = (i, candidate, d) }
            }
            guard let chosen = best else { break }
            done[chosen.index] = true
            result.append(chosen.path)
            position = chosen.path.isClosed ? (chosen.path.start ?? position) : (chosen.path.end ?? position)
        }
        return result
    }

    private func bestOrientation(of path: Polyline, from position: Point) -> Polyline {
        guard allowStartChange else { return path }
        if path.isClosed {
            guard path.points.count <= 4000 else { return path }
            var bestIndex = 0
            var bestDistance = Double.infinity
            for (i, p) in path.points.enumerated() {
                let d = position.distance(to: p)
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            return path.rotated(startingAt: bestIndex)
        }
        if let s = path.start, let e = path.end, position.distance(to: e) < position.distance(to: s) {
            return path.reversed()
        }
        return path
    }
}
