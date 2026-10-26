//
// 源自 Xrash（github.com/owngoal-dev/Xrash，MIT License, OwnGoal Studio）
// 目录：Packages/XrashKit/Sources/XrashReport
// 本目录为逐文件原样搬入，解析逻辑未改；本地改动仅限 Swift 6 并发标注 nonisolated(unsafe)，共 3 行.
/// The one lookup every decoder and renderer needs, written once so the bounds
/// check cannot be forgotten in the next one.
extension [BinaryImage] {
    /// The image a frame names — nil when it names none, or names one the
    /// report never listed, which a truncated file does.
    func image(for frame: Frame) -> BinaryImage? {
        frame.imageIndex.flatMap { indices.contains($0) ? self[$0] : nil }
    }

    /// The image whose mapped range holds `address` — nil when none does.
    /// A zero-sized image has no range and never matches. Public because the
    /// app asks it too: a thread sampled without a stack is a bare program
    /// counter, and naming the image it fell in is this same lookup.
    public func index(containing address: UInt64) -> Int? {
        firstIndex { address >= $0.base && $0.size > 0 && address - $0.base < $0.size }
    }
}
