//
//  Cornucopia – (C) Dr. Lauer Information Technology
//
import Foundation

public extension UDS {

    /// Unit and Scaling Ids (OAS) as defined by SAE J1979DA:201408, Appendix E
    enum UnitAndScalingId: UInt8 {

        case rotationalFrequency                = 0x07
        case secondPerBitUnsigned               = 0x11

        // Custom additions based on J1979 formulas (IDs are placeholders/internal)
        case percentOneByte                     = 0xF0
        case percentOneByteSigned               = 0xF1
        case temperatureOneByte                 = 0xF2
        case pressureKPaOneByte                 = 0xF3
        case pressureThreeKPaOneByte            = 0xF4
        case pressureTenKPaTwoBytes             = 0xF5
        case pressureHighRangeTwoBytes          = 0xF6
        case distanceTwoBytes                   = 0xF7
        case voltageTwoBytes                    = 0xF8
        case ratioTwoBytes                      = 0xF9
        case countOneByte                       = 0xFA
        case percentTwoBytes                    = 0xFB // 100/255 * A + B? No usually AB/2.55? Check specific PIDs.
        case pressurePaSignedTwoBytes           = 0xFC
        case temperatureTwoBytes                = 0xFD
        case countTwoBytes                      = 0xFE

        func doubleUnit(for bytes: [UInt8]) -> (Double, Unit) {
            switch self {
                case .rotationalFrequency:
                    let hi = UInt(bytes[0])
                    let lo = UInt(bytes[1])
                    return (0.25 * Double(hi << 8 + lo), UnitSpeed.CC_RPM)
                case .secondPerBitUnsigned:
                    let hi = UInt(bytes[0])
                    let lo = UInt(bytes[1])
                    return (1.0 * Double(hi << 8 + lo), UnitDuration.seconds)

                case .percentOneByte:
                    return (Double(bytes[0]) * 100.0 / 255.0, Unit.CC_percent)
                case .percentOneByteSigned:
                    return ((Double(bytes[0]) - 128.0) * 100.0 / 128.0, Unit.CC_percent)
                case .temperatureOneByte:
                    return (Double(bytes[0]) - 40.0, UnitTemperature.celsius)
                case .pressureKPaOneByte:
                    return (Double(bytes[0]), UnitPressure.kilopascals)
                case .pressureThreeKPaOneByte:
                    return (Double(bytes[0]) * 3.0, UnitPressure.kilopascals)
                case .pressureTenKPaTwoBytes:
                    let val = (Double(bytes[0]) * 256.0 + Double(bytes[1]))
                    return (val * 10.0, UnitPressure.kilopascals)
                case .pressureHighRangeTwoBytes:
                    let val = (Double(bytes[0]) * 256.0 + Double(bytes[1]))
                    return (val * 0.079, UnitPressure.kilopascals)
                case .distanceTwoBytes:
                    let val = (Double(bytes[0]) * 256.0 + Double(bytes[1]))
                    return (val, UnitLength.kilometers)
                case .voltageTwoBytes:
                    let val = (Double(bytes[0]) * 256.0 + Double(bytes[1]))
                    return (val / 1000.0, UnitElectricPotentialDifference.volts)
                case .ratioTwoBytes:
                    let val = (Double(bytes[0]) * 256.0 + Double(bytes[1]))
                    return (val * 2.0 / 65536.0, Unit.CC_ratio)
                case .countOneByte:
                     return (Double(bytes[0]), Unit.CC_count)
                case .percentTwoBytes:
                     let val = (Double(bytes[0]) * 256.0 + Double(bytes[1]))
                     return (val * 100.0 / 255.0, Unit.CC_percent) // Check formula, usually it's specific
                case .pressurePaSignedTwoBytes:
                    let val = Int16(Int(bytes[0]) << 8 | Int(bytes[1]))
                    return (Double(val) / 4.0, UnitPressure.pascals) // J1979 0x32: (A*256+B)/4 Pa (Signed) is typical but some sources say /4 is for signed?
                    // Actually, 0x32 Evap Vapor Pressure is often Signed 2 bytes (A*256+B)/4 Pa.
                    // Let's assume standard 2's complement for 2 bytes if using Int16.
                case .temperatureTwoBytes:
                     let val = (Double(bytes[0]) * 256.0 + Double(bytes[1]))
                     return (val / 10.0 - 40.0, UnitTemperature.celsius)
                case .countTwoBytes:
                     let val = (Double(bytes[0]) * 256.0 + Double(bytes[1]))
                     return (val, Unit.CC_count)
            }
        }
    }
}
