//
//  Cornucopia – (C) Dr. Lauer Information Technology
//
import Foundation

public extension UDS {

    enum KWP {
        public static var HeaderLength: Int = "87F110".count
    }
}

public extension UDS.KWP {

    /// A KWPISOTP encoder, see ISO14230-4
    final class Encoder: UDS.BusProtocolEncoder {

        public init() { }

        /// Encode a byte stream by inserting the appropriate framing control bytes as per ISOTP
        public func encode(_ bytes: [UInt8]) throws -> [UInt8] {
            throw UDS.Error.encoderError(string: "KWP encoding not yet implemented")
        }
    }

    /// A KWP decoder, see ISO14230-4
    final class Decoder: UDS.BusProtocolDecoder {

        public init() { }

        /// Decode a byte stream consisting on multiple individual concatenated frames by removing the protocol framing bytes as per KWP
        public func decode(_ bytes: [UInt8]) throws -> [UInt8] {
            // Assumes headers (3 bytes) and checksum (1 byte) are present
            guard bytes.count >= 4 else {
                throw UDS.Error.decoderError(string: "KWP frame too short: \(bytes.count)")
            }
            // Strip 3 bytes header and 1 byte checksum
            return Array(bytes[3..<bytes.count-1])
        }
    }
}
