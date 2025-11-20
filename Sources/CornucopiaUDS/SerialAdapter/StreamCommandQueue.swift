//
//  Cornucopia – (C) Dr. Lauer Information Technology
//
import CoreFoundation
import CornucopiaCore
import Foundation

private var logger = Cornucopia.Core.Logger(category: "StreamCommandQueue")

public protocol _StreamCommandQueueDelegate: AnyObject {
    func streamCommandQueueDetectedEOF(_ streamCommandQueue: StreamCommandQueue)
    func streamCommandQueueDetectedError(_ streamCommandQueue: StreamCommandQueue)
}

// Internal delegate to bridge Stream (NSObject) to Actor
class StreamMonitor: NSObject, StreamDelegate {
    weak var actor: StreamCommandQueue?

    init(actor: StreamCommandQueue) {
        self.actor = actor
    }

    func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        guard let actor = self.actor else { return }
        Task {
            await actor.handleStreamEvent(stream, eventCode: eventCode)
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public actor StreamCommandQueue {

    public typealias CompletionHandler = (String) -> ()
    public typealias InputStreamConfigurationHandler = (InputStream) -> ()
    public typealias Delegate = _StreamCommandQueueDelegate

    class Command {
        let request: Data
        let termination: Data
        let timeout: TimeInterval
        let dummy: Bool

        var continuation: CheckedContinuation<String, Never>?
        var pendingBytesToSend: Data
        var response = Data()
        var timestamp: CFTimeInterval?
        var timeoutTask: Task<Void, Never>?

        init(request: Data, termination: Data, timeout: TimeInterval, dummy: Bool, continuation: CheckedContinuation<String, Never>, pendingBytesToSend: Data) {
            self.request = request
            self.termination = termination
            self.timeout = timeout
            self.dummy = dummy
            self.continuation = continuation
            self.pendingBytesToSend = pendingBytesToSend
        }
    }

    private let input: InputStream
    private let output: OutputStream
    private let termination: String?
    private var pending: [Command] = []
    private var active: Command?
    private var mocks: [String: String] = [:]

    private var monitor: StreamMonitor!

    public var inputConfigurationHandler: InputStreamConfigurationHandler?
    public weak var delegate: Delegate?

    public init(input: InputStream, output: OutputStream, termination: String? = nil) {
        self.input = input
        self.output = output
        self.termination = termination
    }

    public func setDelegate(_ delegate: Delegate) {
        self.delegate = delegate
    }

    public func configure() {
        self.monitor = StreamMonitor(actor: self)
        self.input.delegate = self.monitor
        self.output.delegate = self.monitor

        // Schedule on main run loop as streams require a run loop
        DispatchQueue.main.async {
            self.input.schedule(in: RunLoop.current, forMode: .default)
            self.output.schedule(in: RunLoop.current, forMode: .default)
            self.input.open()
            // Output opened on demand
        }
    }

    deinit {
        let input = self.input
        let output = self.output
        DispatchQueue.main.async {
            input.close()
            output.close()
        }
    }

    public func send(command: String, termination: String? = nil, timeout: TimeInterval = 0) async -> String {
        guard let term = termination ?? self.termination else {
            logger.error("Need either a command termination or the global termination")
            return ""
        }

        return await withCheckedContinuation { continuation in
            guard let requestData = command.data(using: .utf8),
                  let termData = term.data(using: .utf8) else {
                logger.error("Command/Termination not UTF8")
                continuation.resume(returning: "")
                return
            }

            let cmd = Command(request: requestData, termination: termData, timeout: timeout, dummy: command.isEmpty, continuation: continuation, pendingBytesToSend: requestData)
            self.pending.append(cmd)
            if self.active == nil {
                self.handleNextCommand()
            }
        }
    }

    public func flush() {
        logger.debug("Flushing…")
        for cmd in pending {
            cmd.timeoutTask?.cancel()
            cmd.continuation?.resume(returning: "")
            cmd.continuation = nil
        }
        self.pending.removeAll()

        if let active = self.active {
             active.timeoutTask?.cancel()
             active.continuation?.resume(returning: "")
             active.continuation = nil
             self.active = nil
        }
        logger.debug("Flushing complete!")
    }

    public func cleanup() {
        logger.debug("Cleaning up…")
        // Clean up streams on Main Thread
        DispatchQueue.main.async {
            if self.input.streamStatus != .closed {
                self.input.remove(from: RunLoop.current, forMode: .default)
                self.input.close()
            }
            if self.output.streamStatus != .closed {
                self.output.remove(from: RunLoop.current, forMode: .default)
                self.output.close()
            }
        }
        logger.debug("Cleaned up!")
    }

    func handleStreamEvent(_ stream: Stream, eventCode: Stream.Event) {
        logger.trace("Handling stream \(stream) event \(eventCode)")

        if stream == self.input {
            switch eventCode {
                case .openCompleted:
                    if let configurationHandler = self.inputConfigurationHandler {
                        configurationHandler(input)
                    }
                    if self.active != nil { self.handleActiveCommand() }

                case .hasBytesAvailable:
                    self.handleBytesAvailable()

                case .errorOccurred:
                    self.handleError(on: stream)

                default:
                    break
            }
        } else if stream == self.output {
            switch eventCode {
                case .openCompleted, .hasSpaceAvailable:
                    if self.active != nil { self.handleActiveCommand() }

                case .errorOccurred:
                    self.handleError(on: stream)

                default:
                    break
            }
        }
    }
}

//MARK: - Helpers
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
private extension StreamCommandQueue {

    static var BufferSize = 1024

    // Helper to get string from data for logging/mocking
    func string(from data: Data) -> String {
        return String(data: data, encoding: .utf8) ?? ""
    }

    func handleNextCommand() {
        guard !self.pending.isEmpty else {
            logger.trace("No more commands pending")
            return
        }

        self.active = self.pending.removeFirst()
        self.handleActiveCommand()
    }

    func handleActiveCommand() {
        guard let active = self.active else { return }

        guard self.input.streamStatus == .open else {
            logger.trace("Input stream not open yet… waiting")
            return
        }

        guard self.output.streamStatus == .open else {
            logger.trace("Output stream not open yet… opening")
            self.output.open()
            return
        }

        guard self.output.hasSpaceAvailable else {
            logger.trace("No space available yet… waiting")
            return
        }

        let requestString = string(from: active.request)
        if let mockResponse = self.mocks[requestString] {
            logger.debug("Encountered mock request \(requestString), synthesizing mocked response \(mockResponse)")
            self.complete(active, with: mockResponse)
            return
        }

        if active.dummy {
            logger.trace("Encountered dummy command, synthesizing an empty response")
            self.complete(active, with: "")
            return
        }

        guard !active.pendingBytesToSend.isEmpty else {
            logger.trace("No more bytes to send, already waiting for the response")
            return
        }

        let bytesWritten = active.pendingBytesToSend.withUnsafeBytes {
            self.output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: active.pendingBytesToSend.count)
        }

        // let writtenBytes = active.pendingBytesToSend.prefix(bytesWritten)
        // logger.trace("Wrote \(bytesWritten)")

        active.pendingBytesToSend.removeFirst(bytesWritten)

        guard active.pendingBytesToSend.count > 0 else {
            logger.trace("No more bytes to send, waiting for the response…")
            active.timestamp = CFAbsoluteTimeGetCurrent()

            if active.timeout > 0 {
                active.timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(active.timeout * 1_000_000_000))
                    if !Task.isCancelled {
                        await self.handleCommandTimeout()
                    }
                }
            }
            return
        }
    }

    func handleBytesAvailable() {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.BufferSize)
        defer { buffer.deallocate() }
        let bytesRead = self.input.read(buffer, maxLength: Self.BufferSize)
        logger.trace("Read \(bytesRead)")

        guard bytesRead >= 0 else {
            logger.notice("Error during reading")
            return
        }
        if bytesRead == 0 {
            logger.info("EOF encountered")
            self.cleanup()
            self.delegate?.streamCommandQueueDetectedEOF(self)
            return
        }
        guard let active = self.active else {
            logger.info("Ignoring unsolicited bytes")
            return
        }
        active.timeoutTask?.cancel()

        // Sanitizing pass
        var sanitized = Data()
        for i in 0..<bytesRead {
            if buffer[i] >= 32 || buffer[i] == 13 || buffer[i] == 10 { // Basic ASCII printable + CR/LF check
                sanitized.append(buffer[i])
            } else {
                 logger.trace("Stripping byte value \(buffer[i])")
            }
        }
        active.response.append(sanitized)

        if let terminationRange = active.response.range(of: active.termination, options: .backwards),
           terminationRange.upperBound == active.response.endIndex {

            active.response.removeSubrange(terminationRange)
            let response = String(data: active.response, encoding: .utf8) ?? ""

            let startTime = active.timestamp ?? CFAbsoluteTimeGetCurrent()
            let duration = String(format: "%04.0f ms", 1000 * (CFAbsoluteTimeGetCurrent() - startTime))
            logger.debug("Command processed [\(duration)]: '\(self.string(from: active.request))' => '\(self.string(from: active.response))'")
        active.response.removeSubrange(terminationRange)
        guard let response = String(data: active.response, encoding: .utf8) else {
            logger.error("Data Encoding Error - Could not convert response to UTF8")
            active.handler("") // Fail gracefully with empty response
            self.active = nil
            self.handleNextCommand()
            return
        }

        let startTime = active.timestamp ?? CFAbsoluteTimeGetCurrent()
        let duration = String(format: "%04.0f ms", 1000 * (CFAbsoluteTimeGetCurrent() - startTime))
        logger.debug("Command processed [\(duration)]: '\(active.request.CC_debugString)' => '\(active.response.CC_debugString)'")
        active.handler(response)

            self.complete(active, with: response)
        }
    }

    func handleCommandTimeout() {
        guard let active = self.active else { return }
        logger.notice("Timeout while waiting for a response to \(self.string(from: active.request))")
        self.complete(active, with: "")
    }
        guard let active = self.active else {
            logger.error("Command timeout called without active command!?")
            return
        }
        logger.notice("Timeout while waiting for a response to \(active.request.CC_debugString)")

    func complete(_ command: Command, with response: String) {
        command.timeoutTask?.cancel()
        command.continuation?.resume(returning: response)
        command.continuation = nil
        self.active = nil
        self.handleNextCommand()
    }

    func handleError(on stream: Stream) {
        logger.notice("Error on stream \(stream)")
        self.delegate?.streamCommandQueueDetectedError(self)
    }
}
