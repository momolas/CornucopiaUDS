//
//  Cornucopia – (C) Dr. Lauer Information Technology
//
import Foundation

public extension UDS {

    enum J1850 {
        // J1850 usually has 3 bytes header
    }
}

public extension UDS.J1850 {

    /// A J1850 decoder
    final class Decoder: UDS.BusProtocolDecoder {

        public init() { }

        /// Decode a byte stream
        public func decode(_ bytes: [UInt8]) throws -> [UInt8] {
            // Assumes headers (3 bytes) and CRC (1 byte) are present
            guard bytes.count >= 4 else {
                throw UDS.Error.decoderError(string: "J1850 frame too short: \(bytes.count)")
            }
            // Strip 3 bytes header and 1 byte checksum
            return Array(bytes[3..<bytes.count-1])
        }
    }
}
