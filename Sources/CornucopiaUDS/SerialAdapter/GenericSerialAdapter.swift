//
//  Cornucopia – (C) Dr. Lauer Information Technology
//
import Foundation
import CornucopiaCore

fileprivate let logger = Cornucopia.Core.Logger(category: "GenericSerialAdapter")

public extension UDS {

    typealias RawCompletionHandler = ([UInt8]) -> ()
    typealias StringCompletionHandler = (String) -> ()

    /// A generic serial command adapter, i.e. using (relatively) low-cost _OBD2 to RS232_ adapters, such as
    /// ```markdown
    ///  *==================================================
    ///  *   VENDOR       CHIPSET     MODEL
    ///  *==================================================
    ///  * ELM ELECTRONICS ELM327    Various Clones
    ///  * OBD SOLUTIONS   STN11xx   OBDLINK SX, OBDLINK MX WiFi, etc.
    ///  * OBD SOLUTIONS   STN22xx   OBDLINK MX+, OBDLINK CX, etc.
    ///  * WGSoft.de       CUSTOM    UniCarScan 2000 (CAUTION!)
    ///  *==================================================
    /// ```
    @available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
    class GenericSerialAdapter: BaseAdapter {

        private var commandProvider: StringCommandProvider
        private var commandQueue: StreamCommandQueue

        private var header = Header(0x7DF) // start out with OBD2 broadcast header
        private var replyHeader = Header(0x000) // none set
        private var stnSendFragmentation = false
        private var stnReceiveFragmentation = false
        private var desiredBusProtocol: BusProtocol = .unknown

        public enum ICType: String {
            case unknown = "???"
            case elm327  = "ELM327"
            case stn11xx = "STN11xx"
            case stn22xx = "STN22xx"
            case unicars = "UniCarScan"
        }
        public var icType = ICType.unknown {
            didSet {
                switch self.icType {
                    case .stn11xx:
                        self.maximumAutoSegmentationFrameLength = 0x7FF // STPX
                    case .stn22xx:
                        self.maximumAutoSegmentationFrameLength = 0xFFF // STPX
                    case .unicars:
                        self.maximumAutoSegmentationFrameLength = 0xFF  // automatic ISOTP
                    default:
                        self.maximumAutoSegmentationFrameLength = 0
                }
                self.mtu = self.maximumAutoSegmentationFrameLength > 0 ? self.maximumAutoSegmentationFrameLength : 8
            }
        }
        public var identification: String = "???"
        public var name: String = "Unspecified"
        public var vendor: String = "Unknown"
        public var serial: String = "Unknown"
        public var version: String = "Unknown"

        public var hasAutoSegmentation: Bool = false
        public var hasSmallFrameNoResponse: Bool = false
        public var hasFullFrameNoResponse: Bool = false
        public var canAutoFormat: Bool = true // CAN auto format is true by default for all ELM327-compatible serial adapters
        public var detectedECUs: [String] = []
        public var maximumAutoSegmentationFrameLength: Int = 0

        public init(inputStream: InputStream, outputStream: OutputStream, commandProvider: StringCommandProvider? = nil) {
            self.commandProvider = commandProvider ?? DefaultStringCommandProvider()

            // Prepare handler
            let handler: StreamCommandQueue.InputStreamConfigurationHandler = { stream in
                 // Note: We capture 'self' here. 'self' is not fully initialized until super.init calls.
                 // But we pass this closure to commandQueue init.
                 // Swift allows capturing self in closure if we are careful, but here we are in init.
                 // We can use a weak capture of a future reference, or pass self after super.init.
                 // However, StreamCommandQueue init takes the handler.
                 // We can use a workaround or just assume NotificationCenter handles the object identity.
                 // Actually, 'self' cannot be used before super.init().
                 // We need a way to post the notification with 'self' as object.
                 // Option: Use a proxy object or pass the handler later? But we just made it immutable in init.
                 // Solution: The handler is called when stream opens. That happens in 'configure()'.
                 // By then 'self' is initialized. But we need to create the closure now.
                 // We can't capture 'self' before super.init.
                 // We can use a class box or lazy var?
                 // Actually, we can make 'inputConfigurationHandler' mutable on Actor if we set it via async setter, but we want to avoid that.
                 // Alternatively, we pass a static function that looks up the adapter? No.
                 // Simplest: Make StreamCommandQueue accept the handler in 'configure()' instead of 'init'.
                 // But I just moved it to init.
                 // Let's revert that part? No, 'configure()' is better for avoiding init race.
                 // Let's change StreamCommandQueue to take handler in configure().
            }
            // I will proceed with changing StreamCommandQueue to take handler in configure() in next step.
            // For now, I'll revert to StreamCommandQueue init logic if I can't capture self.
            // Wait, I can initialize commandQueue with a dummy handler or nil, and set it later?
            // Property is 'let'.
            // I will change property to 'private(set) var' and add a method to set it, or pass in configure.

            // Let's use 'configure' to pass the handler.
            self.commandQueue = StreamCommandQueue(input: inputStream, output: outputStream, termination: ">")
            super.init()

            Task {
                await self.setDelegateAndConfigure()
            }
        }

        private func setDelegateAndConfigure() async {
             await self.commandQueue.setDelegate(self)
             await self.commandQueue.configure { [weak self] stream in
                 guard let self = self else { return }
                 NotificationCenter.default.post(name: Self.CanInitializeDevice, object: self, userInfo: ["stream": stream] )
             }
        }

        public override func connect(via busProtocol: BusProtocol = .auto) async {
            precondition(self.state == .created, "It is only valid to call this during state .created. Current State is \(self.state)")
            self.desiredBusProtocol = busProtocol
            self.updateState(.searching)

            // Trigger init sequence handled by state change notification/observer in BaseAdapter
        }

        // Deprecated synchronous connect
        public override func connect(via busProtocol: BusProtocol = .auto) {
            Task {
                await self.connect(via: busProtocol)
            }
        }

        public func sendString(_ string: String) async -> String {
            let timeout = self.state == .connected ? 5.0 : 10.0
            return await self.commandQueue.send(command: string, timeout: timeout)
        }

        // Deprecated
        public func sendString(_ string: String, then: @escaping(StringCompletionHandler)) {
            Task {
                let result = await self.sendString(string)
                then(result)
            }
        }

        public override func send(message: UDS.Message, expectedResponses: Int? = nil) async throws -> UDS.Message {
             var message = message

            do {
                message.bytes = try self.busProtocolEncoder!.encode(message.bytes)
            } catch let error as UDS.Error {
                throw error
            } catch {
                throw UDS.Error.encoderError(string: error.localizedDescription)
            }

            let responses: UDS.Messages
            if ( message.bytes.count > 8 ) && ( self.icType == .stn11xx || self.icType == .stn22xx ) {
                responses = try await self.stnSendRaw(message: message, expectedResponses: expectedResponses)
            } else {
                responses = try await self.sendRaw(message: message, expectedResponses: expectedResponses)
            }

            //TODO: Change the UDS.MessageHandler into a Result<Error, UDS.Message>, else we can't convey low level errors over to the next logical layer
            // precondition(responses.count > 0, "Did not receive at least a single CAN frame")
            if responses.isEmpty {
                throw UDS.Error.noResponse
            }

            let sid = self.canAutoFormat ? message.bytes[0] : message.bytes[1]

            let validResponses = responses.filter { response in
                guard response.bytes[0] == UInt8(0x03) else { return true }
                guard response.bytes[1] == UDS.NegativeResponse else { return true }
                guard response.bytes[2] == sid else { return true }
                guard response.bytes[3] == UDS.NegativeResponseCode.requestCorrectlyReceivedResponsePending.rawValue else { return true }
                let transient = responses[0].bytes[1..<4].map { String(format: "0x%02X ", $0) }.joined()
                logger.trace("Ignoring transient UDS response \(transient)")
                return false
            }
            //FIXME: Ensure all headers are the same
            var bytes = [UInt8]()
            validResponses.forEach { response in
                bytes += response.bytes
            }
            do {
                bytes = try self.busProtocolDecoder!.decode(bytes)
                let assembled: UDS.Message = .init(id: validResponses.first!.id, bytes: bytes)
                return assembled
            } catch let error as UDS.Error {
                 throw error
            } catch {
                throw UDS.Error.decoderError(string: error.localizedDescription)
            }
        }

        public override func send(message: UDS.Message, expectedResponses: Int? = nil, then: @escaping(UDS.MessageResultHandler)) {
            Task {
                do {
                    let result = try await self.send(message: message, expectedResponses: expectedResponses)
                    then(.success(result))
                } catch let error as UDS.Error {
                    then(.failure(error))
                } catch {
                    // Should not happen due to internal wrapping but safe fallback
                    then(.failure(.busError(string: error.localizedDescription)))
                }
            }
        }

        public override func sendRaw(message: UDS.Message, expectedResponses: Int? = nil) async throws -> UDS.Messages {

             // check current header arbitration
            if self.header != message.id {
                let ok = try await self.send(command: .setHeader(id: message.id)).success
                guard ok else {
                     logger.notice("Can't set header arbitration")
                     throw UDS.Error.unrecognizedCommand
                }
                self.header = message.id

                // check current receive arbitration
                if self.replyHeader != message.reply {
                    let okRx = try await self.send(command: .canReceiveArbitration(id: message.reply)).success
                    guard okRx else {
                        logger.notice("Can't set receive arbitration")
                        throw UDS.Error.unrecognizedCommand
                    }
                    self.replyHeader = message.reply
                }
            }

            let response = try await self.send(command: .data(bytes: message.bytes), expectedResponses: expectedResponses)
             switch response {
                case .failure(let error):
                    throw error
                case .success(let messages as UDS.Messages):
                    return messages
                case .success(_):
                    // Should match Messages for .data command. But instead of crashing, we throw.
                    throw UDS.Error.unexpectedResponse
            }
        }

        public override func sendRaw(message: UDS.Message, expectedResponses: Int? = nil, then: @escaping(UDS.MessagesResultHandler)) {
            Task {
                do {
                    let result = try await self.sendRaw(message: message, expectedResponses: expectedResponses)
                    then(.success(result))
                } catch let error as UDS.Error {
                    then(.failure(error))
                } catch {
                     then(.failure(.busError(string: error.localizedDescription)))
                }
            }
        }

        override func didUpdateState() {
            // This method is called synchronously by NotificationCenter.
            // We need to launch a task to handle state transitions which involve async I/O
            Task {
                await self.handleStateUpdateAsync()
            }
        }

        private func handleStateUpdateAsync() async {
             switch self.state {

                case .searching:
                    await self.sendInitSequence()

                case .configuring:
                    await self.sendConfigSequence()

                default:
                    break
            }
        }

        public override func shutdown() {
            self.updateState(.gone)
            Task {
                await self.commandQueue.cleanup()
            }
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
private extension UDS.GenericSerialAdapter {

    /// Sends a UDS message by using the proprietary STPX command found on STN chipsets
    private func stnSendRaw(message: UDS.Message, expectedResponses: Int? = nil) async throws -> UDS.Messages {

        // check current header arbitration
        if self.header != message.id {
             let ok = try await self.send(command: .setHeader(id: message.id)).success
             guard ok else {
                 logger.notice("Can't set header arbitration")
                 throw UDS.Error.unrecognizedCommand
             }
             self.header = message.id

             // check current receive arbitration
             if self.replyHeader != message.reply {
                 let okRx = try await self.send(command: .canReceiveArbitration(id: message.reply)).success
                 guard okRx else {
                     logger.notice("Can't set receive arbitration")
                     throw UDS.Error.unrecognizedCommand
                 }
                 self.replyHeader = message.reply
             }
        }

        let announceResponse = try await self.send(command: .stnCanTransmitAnnounce(count: message.bytes.count), expectedResponses: expectedResponses)
        switch announceResponse {
            case .failure(let error):
                throw error
            case .success(_):
                let actualResponse = try await self.send(command: .data(bytes: message.bytes), expectedResponses: expectedResponses)
                switch actualResponse {
                    case .failure(let error):
                        throw error
                    case .success(let messages as UDS.Messages):
                        return messages
                    case .success(_):
                        throw UDS.Error.unexpectedResponse
                }
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
private extension UDS.GenericSerialAdapter {

    // Async version of command provider helper
    func send(command: StringCommand, expectedResponses: Int? = nil) async throws -> ResponseResult {
        guard self.state != .notFound, self.state != .gone, self.state != .unsupportedProtocol else {
            logger.notice("Ignoring commands during state \(self.state)")
            // Throw or return error? Returning failure seems appropriate as per ResponseResult
            // But ResponseResult is based on command.
            // Let's assume if state is bad we throw disconnected or similar.
            throw UDS.Error.disconnected
        }

        guard let (request, responseConverter) = self.commandProvider.provide(command: command) else {
            logger.notice("Ignoring unresolved command: \(command)")
             throw UDS.Error.unrecognizedCommand
        }

        var string = request
        if let expectedResponses = expectedResponses {
            string.append("\(expectedResponses)\r")
        } else {
            string.append("\r")
        }

        let stringResponse = await self.sendString(string)
        let result = responseConverter(stringResponse, self)
        return result
    }

    // Wrapper for synchronous callback compatibility
    func send(command: StringCommand, expectedResponses: Int? = nil, then: @escaping((ResponseResult)->())) {
        Task {
            do {
                let result = try await self.send(command: command, expectedResponses: expectedResponses)
                then(result)
            } catch {
                // Fallback failure
                 then(.failure(.noResponse)) // Simplified
            }
        }
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
extension UDS.GenericSerialAdapter: StreamCommandQueue.Delegate {

    public func streamCommandQueueDetectedEOF(_ streamCommandQueue: StreamCommandQueue) {
        // guard self.commandQueue == streamCommandQueue else { return } // Actor equality? Identifiable?
        // Actor equality is reference equality
        // But we can't easily check it synchronously if isolated?
        // Actually we can check === if both are actors.
        // But we can assume it's ours since we are the delegate.
        self.updateState(.gone)
    }

    public func streamCommandQueueDetectedError(_ streamCommandQueue: StreamCommandQueue) {
        self.updateState(.gone)
    }
}

@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
private extension UDS.GenericSerialAdapter {

    private static let ELM327_DEFAULT_VERSION = "OBDII to RS232 Interpreter"

    func sendInitSequence() async {

        let sequence: [StringCommand] = [
            .dummy,
            .reset,
            .spaces(on: false),
            .echo(on: false),
            .linefeed(on: false),
            .showHeaders(on: true),
            .identify,
            .version1,
            .version2,
            .stnExtendedIdentify,
            .stnDeviceIdentify,
            .stnSerialNumber,
            .stnCanSegmentationTransmit(on: true),
            .unicarsIdentify,
            .setProtocol(p: self.desiredBusProtocol),
            .connect,
            .probeAutoSegmentation,
            .probeSmallFrameNoResponse,
            //NOTE: These guys seem to get non-CAN protocols into a strange state, so we better not send them for now
            //.canAutoFormat(on: false),
            //.probeFullFrameNoResponse,
            //.canAutoFormat(on: true),
        ]

        for command in sequence {

            do {
                let response = try await self.send(command: command)

                switch command {
                    case .canAutoFormat(let on):
                        guard case .success(_) = response else { continue }
                        self.canAutoFormat = on

                    case .connect:
                        guard case .success(let ecus as [String]) = response, !ecus.isEmpty else { continue }
                        self.detectedECUs = ecus

                    case .dummy:
                        // For dummy, failure is expected, but if error == noResponse we proceed to initializing?
                        // Original logic: failure(.noResponse) -> initializing. else -> notFound + flush.
                        if case .failure(let error) = response, error == .noResponse {
                            self.updateState(.initializing)
                        } else {
                            self.updateState(.notFound)
                            await self.commandQueue.flush()
                        }

                    case .identify:
                        guard case .success(let name as String) = response else { continue }
                        let components = name.components(separatedBy: " ")
                        if components.count == 2 {
                            self.identification = components[0]
                            self.version = components[1]
                        } else {
                            self.identification = name
                        }
                        self.icType = .elm327

                    case .probeAutoSegmentation:
                        guard case .success(_) = response else { continue }
                        self.hasAutoSegmentation = true

                    case .probeSmallFrameNoResponse:
                        guard case .success(let answer as String) = response else { continue }
                        self.hasSmallFrameNoResponse = answer.isEmpty

                    case .probeFullFrameNoResponse:
                        guard case .success(_) = response else { continue }
                        self.hasFullFrameNoResponse = true

                    case .stnExtendedIdentify:
                        guard case .success(let id as String) = response else { continue }
                        let components = id.components(separatedBy: " ")
                        if components.count >= 3 {
                            self.identification = components[0]
                            self.version = components[1]
                        } else {
                            self.identification = id
                        }
                        self.icType = id.starts(with: "STN11") ? .stn11xx : .stn22xx
                        self.vendor = "ScanTool.net"

                    case .stnDeviceIdentify:
                        guard case .success(let id as String) = response else { continue }
                        self.name = id

                    case .stnSerialNumber:
                        guard case .success(let name as String) = response else { continue }
                        self.serial = name

                    case .unicarsIdentify:
                        guard case .success(let name as String) = response else { continue }
                        guard name.contains("WGSoft.de") else { continue }
                        self.name = name.contains("2021") ? "UniCarScan 2100" : "UniCarScan 2000"
                        self.icType = .unicars
                        self.vendor = "WGSoft.de"

                    case .version1:
                        guard case .success(let name as String) = response else { continue }
                        guard name != Self.ELM327_DEFAULT_VERSION else { continue }
                        self.version = name

                    default:
                        break
                }
            } catch {
                 // Log or ignore? Original used callbacks which swallowed generic errors except for specific cases.
            }
        }

        // Post-init
        // self.commandQueue.send(command: "") callback
        _ = await self.commandQueue.send(command: "")

        let info = Info(model: self.name, ic: self.identification, vendor: self.vendor, serialNumber: self.serial, firmwareVersion: self.version)
        self.updateInfo(info)
        self.updateState(.configuring)
    }

    func sendConfigSequence() async {
        let cafMode = !(!self.hasAutoSegmentation && self.hasFullFrameNoResponse)
        var sequence: [StringCommand] = []
        //BUG: At this point of time, the negotiated protocol has not been gathered yet, hence the whole sequence has no effect
        //TODO: Move .describeProtocolNumeric into the init sequence
        if self.negotiatedProtocol.isCAN {
            sequence += [
                .readVoltage,
                .canAutoFormat(on: cafMode),
                .adaptiveTiming(on: false),
            ]
        }
        #if DIAG
        sequence += [
            // <DIAG>
            .setTimeout(0xFF),
            // <DIAG OFF>
            ]
        #endif
        // Enlarge ISOTP timeouts a bit, if we can
        if self.icType == .stn11xx || self.icType == .stn22xx {
            sequence.append(.stnCanSegmentationTimeouts(flowControl: 255, consecutiveFrame: 255))
        }
        // This one _always_ needs to be there, otherwise we will never reach the `.ready` state
        sequence.append(.describeProtocolNumeric)

        for command in sequence {
            do {
                let response = try await self.send(command: command)

                switch command {

                    /*
                    case .readVoltage:
                        guard case .success(let voltage as String) = response else { return }
                        print("voltage: \(voltage)")
                    */

                    case .canAutoFormat(let on):
                        guard case .success(let ok as Bool) = response else { continue }
                        guard ok else { continue }
                        self.canAutoFormat = on

                    case .describeProtocolNumeric:
                        guard case .success(let proto as UDS.BusProtocol) = response, proto != .auto else {
                            self.updateState(.unsupportedProtocol)
                            await self.commandQueue.flush()
                            continue // return in original, but here loop
                        }
                        self.handleProtocolNegotiation(proto)

                    default:
                        break
                }
            } catch {

            }
        }
    }

    // NOTE: handleProtocolNegotiation remains synchronous as it just sets properties
    func handleProtocolNegotiation(_ proto: UDS.BusProtocol) {

        switch proto {

            case .unknown:
                fallthrough
            case .auto:
                fallthrough
            case .j1850_PWM:
                self.busProtocolEncoder = NullProtocolEncoder(maximumFrameLength: 10)
                self.busProtocolDecoder = UDS.J1850.Decoder()
            case .j1850_VPWM:
                self.busProtocolEncoder = NullProtocolEncoder(maximumFrameLength: 11)
                self.busProtocolDecoder = UDS.J1850.Decoder()
            case .iso9141_2:
                self.busProtocolEncoder = NullProtocolEncoder(maximumFrameLength: 7)
                self.busProtocolDecoder = UDS.KWP.Decoder()

            case .kwp2000_5KBPS:
                fallthrough
            case .kwp2000_FAST:
                self.busProtocolEncoder = NullProtocolEncoder(maximumFrameLength: 7)
                self.busProtocolDecoder = UDS.KWP.Decoder()

            case .can_SAE_J1939:
                fallthrough
            case .user1_11B_125K:
                fallthrough
            case .user2_11B_50K:
                fallthrough
            case .can_11B_500K:
                fallthrough
            case .can_29B_500K:
                fallthrough
            case .can_11B_250K:
                fallthrough
            case .can_29B_250K:
                if self.hasAutoSegmentation {
                    self.busProtocolEncoder = NullProtocolEncoder(maximumFrameLength: self.maximumAutoSegmentationFrameLength)
                } else {
                    let maximumFrameLength = self.canAutoFormat ? 7 : 8
                    self.busProtocolEncoder = NullProtocolEncoder(maximumFrameLength: maximumFrameLength)
                }
                self.busProtocolDecoder = UDS.ISOTP.Decoder()

            case .can_FD_11B:
                 fallthrough
            case .can_FD_29B:
                 // CAN FD: MTU is usually 64 bytes.
                 // If adapter supports auto segmentation, use it.
                 // Else, ISOTP encoder handles segmentation based on MTU.
                 self.mtu = 64
                 if self.hasAutoSegmentation {
                      self.busProtocolEncoder = NullProtocolEncoder(maximumFrameLength: self.maximumAutoSegmentationFrameLength > 0 ? self.maximumAutoSegmentationFrameLength : 64)
                 } else {
                      // Manual ISOTP
                      self.busProtocolEncoder = NullProtocolEncoder(maximumFrameLength: 64)
                 }
                 self.busProtocolDecoder = UDS.ISOTP.Decoder()
        }

        self.updateNegotiatedProtocol(proto)
        self.updateState(.connected)
    }
}
