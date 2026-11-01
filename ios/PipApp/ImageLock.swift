import ARKit
import PipCore
import simd

/// Locks an outline to the object itself in 3D, so it stays on it while the object moves.
///
/// When Pip points at something small on an object (a key on a remote, a switch on a panel), the
/// object's face is cut out of the snapshot (SAM's mask of the object, the rest made neutral grey)
/// and handed to ARKit as a reference image of known size (from LiDAR depth). ARKit then follows
/// that image in 3D, 60 times a second: position and orientation. The outline is laid onto the
/// image in millimetres, so wherever the object goes (in a hand, turned, tilted) the outline goes
/// with it. Objects without enough texture are refused by ARKit's own check, and fall back to the
/// image tracker and re-measuring.
struct ImageLock {
    let markID: Int
    let reference: ARReferenceImage
    /// The outline in the image's plane: x to the right, z down the image, y out of it (metres at
    /// the reference's physical size; ARKit's estimated scale is applied on top).
    let local: [[simd_float3]]
    var tracked = false
    var seen = false
    /// When ARKit last tracked the face (CACurrentMediaTime): a lock seen moments ago still says
    /// where the object is (see TrackGate).
    var lastTracked: TimeInterval = 0
    /// When the lock was made: the oldest gives way when there are too many.
    let created = Date()

    var name: String { reference.name ?? "" }

    /// Builds the reference image and the outline in its plane (see ObjectFace). nil when the
    /// region is too small to track.
    static func make(key: SegmentInstance, object: SegmentInstance?, snapshot: FrameSnapshot, distance: Float) -> (image: CGImage, physicalWidth: CGFloat, local: [[simd_float3]])? {
        let focal = CGFloat(snapshot.intrinsics[0][0]) * CGFloat(snapshot.image.height) / snapshot.sensorSize.width
        guard let made = ObjectFace.make(key: key, object: object, image: snapshot.image, focal: focal, distance: distance) else { return nil }
        return (made.image, made.physicalWidth, made.local)
    }
}
