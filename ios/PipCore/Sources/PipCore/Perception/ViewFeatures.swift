import Accelerate
import CoreGraphics
import CoreML
import Foundation
import Vision

/// What each part of a view looks like, in Meta's DINOv2 (ViT-S/14, converted to Core ML by
/// ios/scripts/convert-dinov2.py): features that a change of light alters little, where the
/// described corners of `FeatureMatcher` are lost (2 Nov: the same rooms at 15:22 in daylight and at
/// 16:40 in low sun gave 1 corner view link; DINOv2 found the views and their parts).
///
/// A view is described by its class token (the whole view: which stored view shows the same place)
/// and one token per 14-pixel patch of a 434 × 574 image (31 × 41 patches: which part is which).
public final class ViewFeatures: @unchecked Sendable {
    public static let columns = 31, rows = 41, dim = 384
    public static let inputWidth = 434, inputHeight = 574
    public static let modelName = "DINOv2Small"

    private let model: MLModel
    private let lock = NSLock()

    public init(model: MLModel) {
        self.model = model
    }

    /// Loads the model: a compiled one (the app bundle's DINOv2Small.mlmodelc), or a package that is
    /// compiled first (on the Mac, for pipeval).
    public static func load(from url: URL, computeUnits: MLComputeUnits = .all) throws -> ViewFeatures {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        return ViewFeatures(model: try MLModel(contentsOf: compiled, configuration: config))
    }

    public struct Described: Sendable {
        /// The class token, unit length.
        public var whole: [Float]
        /// Each patch's token, unit length, row after row of `columns` from the top left.
        public var patches: [Float]

        /// How alike two whole views are (cosine).
        public func similarity(to other: Described) -> Float {
            vDSP.dot(whole, other.whole)
        }

        /// A patch's centre in the pixels of an upright image of `width` × `height`.
        public static func centre(of patch: Int, width: Int, height: Int) -> SIMD2<Float> {
            let r = patch / ViewFeatures.columns, c = patch % ViewFeatures.columns
            return SIMD2((Float(c) + 0.5) / Float(ViewFeatures.columns) * Float(width), (Float(r) + 0.5) / Float(ViewFeatures.rows) * Float(height))
        }
    }

    public enum Failure: Error { case input, output }

    /// Describes an upright image (it is scaled to the model's size; snapshots are 3:4 like it).
    public func describe(_ image: CGImage) throws -> Described {
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { throw Failure.input }
        let value = try MLFeatureValue(cgImage: image, constraint: constraint,
                                       options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": value])
        lock.lock()
        let out: MLFeatureProvider
        do { out = try model.prediction(from: provider) } catch { lock.unlock(); throw error }
        lock.unlock()
        guard let tokens = out.featureValue(for: "tokens")?.multiArrayValue, tokens.shape.count == 3,
              tokens.shape[1].intValue == 1 + Self.columns * Self.rows, tokens.shape[2].intValue == Self.dim else { throw Failure.output }
        let count = tokens.shape[1].intValue, dim = Self.dim
        let s1 = tokens.strides[1].intValue, s2 = tokens.strides[2].intValue
        var all = [Float](repeating: 0, count: count * dim)
        if tokens.dataType == .float16 {
            tokens.withUnsafeBufferPointer(ofType: Float16.self) { p in
                for t in 0..<count { for k in 0..<dim { all[t * dim + k] = Float(p[t * s1 + k * s2]) } }
            }
        } else {
            tokens.withUnsafeBufferPointer(ofType: Float.self) { p in
                for t in 0..<count { for k in 0..<dim { all[t * dim + k] = p[t * s1 + k * s2] } }
            }
        }
        // Unit length each.
        for t in 0..<count {
            let range = t * dim..<(t + 1) * dim
            let norm = sqrt(vDSP.sumOfSquares(all[range]))
            if norm > 0 { for k in range { all[k] /= norm } }
        }
        return Described(whole: Array(all[0..<dim]), patches: Array(all[dim...]))
    }
}
