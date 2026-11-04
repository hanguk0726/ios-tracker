import UIKit

public class Crashs: NSObject {
    public static let shared = Crashs()
    private static var fileUrl: URL? = nil
    /// Token of the session that crashed; the report goes out on the next launch,
    /// when the current token belongs to a new session.
    private static var tokenUrl: URL? = nil
    // Handler installed before ours (Crashlytics, Sentry, ...) — must be chained,
    // otherwise this SDK silently disables the app's other crash reporters.
    private static var previousHandler: (@convention(c) (NSException) -> Void)? = nil
    private var isActive = false
    
    private override init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        Crashs.fileUrl = caches?.appendingPathComponent("ASCrash.dat")
        Crashs.tokenUrl = caches?.appendingPathComponent("ASCrash.token")
        if let fileUrl = Crashs.fileUrl,
           FileManager.default.fileExists(atPath: fileUrl.path),
           let crashData = try? Data(contentsOf: fileUrl) {
            let removeReport = {
                try? FileManager.default.removeItem(at: fileUrl)
                if let tokenUrl = Crashs.tokenUrl { try? FileManager.default.removeItem(at: tokenUrl) }
            }
            // No recorded owner (older SDK): any token we hold now is another session's.
            guard let tokenUrl = Crashs.tokenUrl,
                  let owner = try? String(contentsOf: tokenUrl, encoding: .utf8), !owner.isEmpty else {
                removeReport()
                return
            }
            NetworkManager.shared.sendLateMessage(content: crashData, token: owner) { (success) in
                guard success else { return }
                removeReport()
            }
        }
    }

    public func start() {
        guard !isActive else { return }
        Crashs.previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { (exception) in
            DebugUtils.log("<><> captured crash \(exception)")
            let message = ORMobileCrash(name: exception.name.rawValue,
                                     reason: exception.reason ?? "",
                                     stacktrace: exception.callStackSymbols.joined(separator: "\n"))
            // Disk only: the process dies when this handler returns, so async
            // network work never completes. The file is sent via /late on next launch.
            if let fileUrl = Crashs.fileUrl, let token = NetworkManager.shared.currentToken {
                try? message.contentData().write(to: fileUrl)
                if let tokenUrl = Crashs.tokenUrl { try? Data(token.utf8).write(to: tokenUrl) }
            }
            Crashs.previousHandler?(exception)
        }
        isActive = true
    }
    
    public func sendLateError(exception: NSException) {
        let message = ORMobileCrash(name: exception.name.rawValue,
                                 reason: exception.reason ?? "",
                                 stacktrace: exception.callStackSymbols.joined(separator: "\n")
        )
        NetworkManager.shared.sendLateMessage(content: message.contentData(), token: NetworkManager.shared.currentToken) { (success) in
            guard success else { return }
            if let fileUrl = Crashs.fileUrl,
               FileManager.default.fileExists(atPath: fileUrl.path) {
                try? FileManager.default.removeItem(at: fileUrl)
            }
        }
    }
    
    public func stop() {
        if isActive {
            NSSetUncaughtExceptionHandler(Crashs.previousHandler)
            Crashs.previousHandler = nil
            isActive = false
        }
    }
}
