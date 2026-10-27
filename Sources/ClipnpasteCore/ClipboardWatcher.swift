import Foundation

@MainActor
public protocol ClipboardWatcher: AnyObject {
    /// Called for each newly captured clip.
    var onClip: (@MainActor (Clip) -> Void)? { get set }
    func start()
    func stop()
    /// Call right after writing to the pasteboard ourselves, with the pasteboard's new
    /// change count, so the write is not captured again.
    func markOwnWrite(changeCount: Int)
}
