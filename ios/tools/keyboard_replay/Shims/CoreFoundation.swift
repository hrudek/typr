// Linux CoreFoundation neither bridges String to CFString nor implements the Darwin notify center,
// and the replay needs nothing else from it. One process has nobody to notify.

public typealias CFString = String
public typealias CFNotificationName = String
public typealias CFNotificationCallback = (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, String?,
                                           UnsafeRawPointer?, [String: Any]?) -> Void
public enum CFNotificationSuspensionBehavior { case deliverImmediately }
public struct DarwinNotifyCenter {}

public func CFNotificationCenterGetDarwinNotifyCenter() -> DarwinNotifyCenter { DarwinNotifyCenter() }
public func CFNotificationCenterPostNotification(_ center: DarwinNotifyCenter, _ name: String, _ object: UnsafeRawPointer?,
                                                 _ userInfo: [String: Any]?, _ deliverImmediately: Bool) {}
public func CFNotificationCenterAddObserver(_ center: DarwinNotifyCenter, _ observer: UnsafeRawPointer?,
                                            _ callback: CFNotificationCallback?, _ name: String,
                                            _ object: UnsafeRawPointer?, _ behavior: CFNotificationSuspensionBehavior) {}
public func CFNotificationCenterRemoveObserver(_ center: DarwinNotifyCenter, _ observer: UnsafeRawPointer?,
                                               _ name: String?, _ object: UnsafeRawPointer?) {}
