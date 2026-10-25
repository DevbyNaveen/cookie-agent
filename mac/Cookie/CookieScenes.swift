//
//  CookieScenes.swift
//  Cookie
//
//  3D scenes: a small model of a physical thing, built from named simple
//  parts (boxes, spheres, cylinders, cones, capsules), that Cookie can put
//  beside what it says when the shape is the point — how an engine is laid
//  out, what sits inside a pump. The model writes one inline as
//  [SCENE {json}] at the word where it belongs; it is read here into exact
//  Swift types and strictly checked. Anything that doesn't fit (an unknown
//  field, shape or colour, too many parts, a size that isn't a sane number)
//  drops the scene, never the reply. Nothing the model writes is run: the
//  scene is data, drawn by `CookieSceneView`.
//
//  The scene appears at its tag, and each labelled part's label follows,
//  one by one, over the sentence after it.
//

import Foundation
import simd

struct CookieScene: Equatable {
    /// The shapes RealityKit can make on macOS 15: `MeshResource.generateBox`, `generateSphere`,
    /// `generateCylinder`, `generateCone`, and a capsule through `MeshResource(shape:)` from
    /// `ShapeResource.generateCapsule`. There is no torus generator, so there is no torus.
    enum Shape: String { case box, sphere, cylinder, cone, capsule }

    /// Cookie's small palette; glass is always see-through.
    enum Tint: String { case amber, cream, graphite, sky, mint, rose, steel, glass }

    struct Part: Equatable {
        let id: String
        let label: String?
        let shape: Shape
        /// box: width, height, depth. sphere: radius. cylinder, cone, capsule: radius, height (along y;
        /// a capsule's height includes its round ends).
        let size: [Float]
        let position: SIMD3<Float>
        /// Degrees about x, then y, then z.
        let rotation: SIMD3<Float>
        let tint: Tint
        /// Drawn see-through, to show what is inside it.
        let cut: Bool

        var orientation: simd_quatf {
            let r = rotation * (.pi / 180)
            return simd_quatf(angle: r.z, axis: [0, 0, 1]) * simd_quatf(angle: r.y, axis: [0, 1, 0]) * simd_quatf(angle: r.x, axis: [1, 0, 0])
        }

        /// The radius of a ball around the part's centre that holds all of it, however it is turned.
        var reach: Float {
            switch shape {
            case .box: return simd_length(SIMD3(size[0], size[1], size[2])) / 2
            case .sphere: return size[0]
            case .cylinder, .cone, .capsule: return (size[0] * size[0] + size[1] * size[1] / 4).squareRoot()
            }
        }
    }

    let title: String
    let parts: [Part]
    let explode: Bool
    let spin: Bool
    /// UTF-16 offset in the spoken text where the tag sat (`CookieSpeechClock` units).
    var offset = 0

    // MARK: Limits

    static let maxParts = 24
    /// Metres, more or less: no size or position past this, and nothing smaller than `minSize`.
    static let maxExtent: Float = 10
    static let minSize: Float = 0.001
    static let titleLength = 60
    static let labelLength = 28
    /// How far apart an exploded scene's parts end up, as a multiple of their distance from the centre.
    static let explodeSpread: Float = 1.6

    /// The scene a SCENE tag describes, or nil when it isn't one exactly.
    init?(tag: CookieReplyTag) {
        guard tag.kind == "SCENE", let data = tag.body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys).isSubset(of: Self.sceneFields),
              let rawParts = object["parts"] as? [[String: Any]],
              rawParts.allSatisfy({ Set($0.keys).isSubset(of: Self.partFields) }),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        func fits(_ text: String?, _ limit: Int) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= limit else { return nil }
            return text
        }
        guard let title = fits(raw.title, Self.titleLength), (1...Self.maxParts).contains(raw.parts.count) else { return nil }
        var parts: [Part] = []
        for part in raw.parts {
            guard let id = fits(part.id, Self.labelLength), !parts.contains(where: { $0.id == id }),
                  let shape = Shape(rawValue: part.shape), let tint = Tint(rawValue: part.color),
                  let size = Self.numbers(part.size, count: shape == .box ? 3 : shape == .sphere ? 1 : 2, within: Self.minSize...Self.maxExtent),
                  let position = Self.numbers(part.position, count: 3, within: -Self.maxExtent...Self.maxExtent),
                  let rotation = Self.numbers(part.rotation ?? [0, 0, 0], count: 3, within: -360...360) else { return nil }
            if part.label != nil && fits(part.label, Self.labelLength) == nil { return nil }
            // A capsule shorter than its two round ends has no shape.
            if shape == .capsule && size[1] < size[0] * 2 { return nil }
            parts.append(Part(id: id, label: fits(part.label, Self.labelLength), shape: shape, size: size,
                              position: SIMD3(position[0], position[1], position[2]),
                              rotation: SIMD3(rotation[0], rotation[1], rotation[2]), tint: tint, cut: part.cut ?? false))
        }
        self.init(title: title, parts: parts, explode: raw.explode ?? false, spin: raw.spin ?? false, offset: tag.offset)
    }

    init(title: String, parts: [Part], explode: Bool, spin: Bool, offset: Int = 0) {
        self.title = title
        self.parts = parts
        self.explode = explode
        self.spin = spin
        self.offset = offset
    }

    /// The parts that carry a label, in the order their labels appear.
    var labelled: [Part] { parts.filter { $0.label != nil } }

    /// The middle of the parts; the model turns about it and explodes away from it.
    var centroid: SIMD3<Float> {
        parts.reduce(SIMD3<Float>.zero) { $0 + $1.position } / Float(parts.count)
    }

    /// Where a part sits relative to the centroid, assembled or exploded.
    func place(of part: Part, exploded: Bool) -> SIMD3<Float> {
        (part.position - centroid) * (exploded ? Self.explodeSpread : 1)
    }

    /// The radius of a ball around the centroid that holds the whole scene, exploded if it will be.
    var radius: Float {
        max(0.05, parts.map { simd_length(place(of: $0, exploded: explode)) + $0.reach }.max() ?? 0.05)
    }

    var spokenSummary: String {
        ([title] + labelled.compactMap(\.label)).joined(separator: ". ")
    }

    /// Where on the speech clock each beat falls: the scene (and its title) at the tag, then each
    /// label, spread over the sentence after it.
    func revealOffsets(in spoken: String) -> [Int] {
        CookieCard.namedBeats(labelled.compactMap(\.label), from: offset, in: spoken)
    }

    // MARK: Reading

    private static let sceneFields: Set<String> = ["title", "parts", "explode", "spin"]
    private static let partFields: Set<String> = ["id", "label", "shape", "size", "position", "rotation", "color", "cut"]

    private struct Raw: Decodable {
        let title: String
        let parts: [RawPart]
        let explode: Bool?
        let spin: Bool?
    }

    private struct RawPart: Decodable {
        let id: String
        let label: String?
        let shape: String
        let size: [Double]
        let position: [Double]
        let rotation: [Double]?
        let color: String
        let cut: Bool?
    }

    /// Exactly `count` finite numbers, each inside `range`.
    private static func numbers(_ values: [Double], count: Int, within range: ClosedRange<Float>) -> [Float]? {
        guard values.count == count else { return nil }
        let kept = values.compactMap { value -> Float? in
            guard value.isFinite, range.contains(Float(value)) else { return nil }
            return Float(value)
        }
        return kept.count == count ? kept : nil
    }
}
