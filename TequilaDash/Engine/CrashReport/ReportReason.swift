//
// 源自 Xrash（github.com/owngoal-dev/Xrash，MIT License, OwnGoal Studio）
// 目录：Packages/XrashKit/Sources/XrashReport
// 本目录为逐文件原样搬入，未改动任何逻辑；改动只发生在调用方（CrashLogService / CrashLogView）.
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
