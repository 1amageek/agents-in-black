import Foundation
import NIOCore

struct GatewayConnectionErrorClassifier {
    static func isExpectedClientDisconnect(_ error: any Error) -> Bool {
        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNRESET, EPIPE, ENOTCONN:
                return true
            default:
                break
            }
        }

        if let channelError = error as? ChannelError, case .eof = channelError {
            return true
        }

        let message = String(describing: error).lowercased()
        return message.contains("connection reset by peer")
            || message.contains("broken pipe")
            || message.contains("socket is not connected")
    }
}
