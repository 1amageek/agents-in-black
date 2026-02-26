import AIBRuntimeCore
import Foundation
import Logging

public final class LogMux: @unchecked Sendable {
    private let logger: Logger
    private let queue = DispatchQueue(label: "aib.logmux")

    public init(logger: Logger) {
        self.logger = logger
    }

    public func attach(_ handle: ChildHandle) {
        attach(pipe: handle.stdoutPipe, serviceID: handle.serviceID, stream: "stdout")
        attach(pipe: handle.stderrPipe, serviceID: handle.serviceID, stream: "stderr")
    }

    private func attach(pipe: Pipe, serviceID: ServiceID, stream: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self.queue.async {
                text.split(whereSeparator: \.isNewline).forEach { line in
                    self.logger.info("[\(serviceID.rawValue)][\(stream)] \(line)")
                }
            }
        }
    }

    public func detach(_ handle: ChildHandle) {
        handle.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        handle.stderrPipe.fileHandleForReading.readabilityHandler = nil
    }
}
