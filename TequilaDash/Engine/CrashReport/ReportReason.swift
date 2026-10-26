//
// 源自 Xrash（github.com/owngoal-dev/Xrash，MIT License, OwnGoal Studio）
// 目录：Packages/XrashKit/Sources/XrashReport
// 本目录为逐文件原样搬入，解析逻辑未改；本地改动仅限 Swift 6 并发标注 nonisolated(unsafe)，共 3 行.
import Foundation

public extension Report {
    /// `EXC_CRASH (SIGABRT)`, or the termination reason when there is no
    /// exception. Nil for a report whose kind says everything already. The
    /// list row and the notification both say this, so it is decided once.
    var reason: String? {
        if let exception = crash?.exception {
            return exception.typeAndSignal
        }
        if let termination = crash?.termination {
            return termination.namespace ?? termination.indicator
        }
        if let panic {
            return panic.panicString.split(separator: "\n").first.map(String.init)
        }
        if let resource {
            return resource.event
        }
        return nil
    }
}
