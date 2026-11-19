@_exported import Foundation

public func CACurrentMediaTime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
