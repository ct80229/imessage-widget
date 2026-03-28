import Foundation

/// Sends iMessages via AppleScript by controlling the Messages app.
class MessageSender {
    static let shared = MessageSender()

    enum SendError: Error {
        case scriptCompilationFailed
        case scriptExecutionFailed(String)
        case automationDenied
    }

    private var automationDenied = false

    var canSend: Bool { !automationDenied }

    /// Sends a message to a 1-on-1 handle (phone number or Apple ID).
    func send(text: String, to handle: String) async -> Result<Void, SendError> {
        let escaped = escapeAppleScript(text)
        let script = """
            tell application "Messages"
                set targetService to 1st service whose service type = iMessage
                set targetBuddy to buddy "\(handle)" of targetService
                send "\(escaped)" to targetBuddy
            end tell
        """
        return await executeScript(script)
    }

    /// Sends a message to a group chat identified by its chat.guid.
    func sendToGroup(text: String, chatGuid: String) async -> Result<Void, SendError> {
        let escaped = escapeAppleScript(text)
        // Use a more robust approach: find chat by participants or name
        let script = """
            tell application "Messages"
                set theChat to a reference to chat id "\(chatGuid)"
                send "\(escaped)" to theChat
            end tell
        """
        return await executeScript(script)
    }

    private func executeScript(_ source: String) async -> Result<Void, SendError> {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: .failure(.scriptCompilationFailed))
                    return
                }
                var errorDict: NSDictionary?
                script.executeAndReturnError(&errorDict)
                if let error = errorDict {
                    let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                    // OSStatus -1743 means Automation not authorized
                    if let num = error[NSAppleScript.errorNumber] as? Int, num == -1743 {
                        self.automationDenied = true
                        continuation.resume(returning: .failure(.automationDenied))
                    } else {
                        continuation.resume(returning: .failure(.scriptExecutionFailed(msg)))
                    }
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }
    }

    private func escapeAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
