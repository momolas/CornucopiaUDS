//
//  Cornucopia – (C) Dr. Lauer Information Technology
//
import CornucopiaCore
import Foundation

public extension UDS {

    enum OBD2 {

        enum MessageConverter {
            case ascii(range: Range<Int>? = nil)
            case pids(offset: UInt8)
            case monitorStatusSinceDtcCleared
            case uas(_ id: UDS.UnitAndScalingId)
            case uint8
            case localized
        }

        struct MessageSpec {

            let sid: UInt8
            let pid: UInt8
            let mnemonic: String
            let len: Int
            let converter: MessageConverter
            let unit: Unit?

            init(sid: UInt8, pid: UInt8, mnemonic: String, len: Int, converter: MessageConverter, unit: Unit? = nil) {
                self.sid = sid
                self.pid = pid
                self.mnemonic = mnemonic
                self.len = len
                self.converter = converter
                self.unit = unit
            }

            func convert(message: UDS.Message) -> Any? {

                switch self.converter {

                    case .ascii(let range):
                        let range = range ?? 0..<message.bytes.count
                        let startIndex = 2 + range.startIndex
                        let endIndex = min(2 + range.endIndex, message.bytes.count - 1)
                        let asciiBytes = message.bytes[startIndex...endIndex]
                        return asciiBytes.map { String(format: "%c", $0 > 0x08 && $0 < 0x80 ? $0 : 0x2E) }.joined()

                    case .pids(let offset):
                        let pidBytes = message.bytes[2..<6]
                        var pids: [UInt8] = []
                        for pid in 0..<32 {
                            let byte = pidBytes[pidBytes.startIndex + (pid / 8)]
                            let bit: UInt8 = 1 << (7 - (pid % 8))
                            if byte & bit == bit {
                                pids.append(offset + 1 + UInt8(pid))
                            }
                        }
                        return pids

                    case .monitorStatusSinceDtcCleared:
                        let MIL: Bool = message.bytes[2] & 0x80 == 0x80
                        let DTC_CNT = message.bytes[2] & 0x7F
                        let MIS_SUP = message.bytes[3] & 0x01 == 0x01
                        let FUEL_SUP = message.bytes[3] & 0x02 == 0x02
                        let CCM_SUP = message.bytes[3] & 0x04 == 0x04
                        let hasCompressionIgnition = message.bytes[3] & 0x08 == 0x08
                        let MIS_RDY = message.bytes[4] & 0x10 == 0x10
                        let FUEL_RDY = message.bytes[4] & 0x20 == 0x20
                        let CCM_RDY = message.bytes[4] & 0x40 == 0x40
                        _ = message.bytes[4] & 0x80 == 0x80 // ISO/SAE reserved
                        return MonitorStatusSinceDtcCleared(milOn: MIL,
                                                            dtcCount: Int(DTC_CNT),
                                                            misfireMonitoringSupported: MIS_SUP,
                                                            misfireMonitoringReady: MIS_RDY,
                                                            comprehensiveComponentMonitoringSupported: CCM_SUP,
                                                            comprehensiveComponentMonitoringReady: CCM_RDY,
                                                            fuelSystemMonitoringSupported: FUEL_SUP,
                                                            fuelSystemMonitoringReady: FUEL_RDY,
                                                            hasCompressionIgnition: hasCompressionIgnition)

                    case .uas(let uasId):
                        guard message.bytes.count >= 2 + self.len else { return nil }
                        let slice = message.bytes[message.bytes.count - self.len..<message.bytes.count]
                        let bytes = Array(slice)
                        let (double, unit) = uasId.doubleUnit(for: bytes)
                        return Measurement(value: double, unit: unit)

                    case .uint8:
                        guard let unit = self.unit else { return nil }
                        let uint8 = message.bytes.last!
                        return Measurement(value: Double(uint8), unit: unit)

                    case .localized:
                        let uint8 = message.bytes.last!
                        return "OBD2_\(self.mnemonic)_\(uint8, radix: .hex, toWidth: 2)".uds_localized
                }
            }
        }

        static let messageSpecs: [MessageSpec] = [
            // 0x01
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.pids_00_1F, mnemonic: "PIDS_A", len: 1, converter: .pids(offset: 0x00)),                                                       // 0100
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.monitorStatusSinceDtcCleared, mnemonic: "MONITOR_STATUS_SINCE_DTC_CLEARED", len: 4, converter: .monitorStatusSinceDtcCleared), // 0101
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.engineCoolantTemperature, mnemonic: "COOLANT_TEMP", len: 1, converter: .uas(.temperatureOneByte)),                               // 0105
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.engineRPM, mnemonic: "ENGINE_RPM", len: 2, converter: .uas(.rotationalFrequency)),                                             // 010C
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.vehicleSpeed, mnemonic: "VEHICLE_SPEED", len: 1, converter: .uint8, unit: UnitSpeed.kilometersPerHour),                        // 010D
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.standardsCompliance, mnemonic: "OBD_STANDARD", len: 1, converter: .localized),                                                 // 011C
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.engineRunTime, mnemonic: "ENGINE_RUNTIME", len: 2, converter: .uas(.secondPerBitUnsigned)),                                    // 011F

            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.pids_20_3F, mnemonic: "PIDS_B", len: 4, converter: .pids(offset: 0x20)), // 0120

            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.distanceTraveledWhileMILIsActivated, mnemonic: "DISTANCE_TRAVELED_MIL_ON", len: 2, converter: .uas(.distanceTwoBytes)), // 0121
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.fuelRailPressure, mnemonic: "FUEL_RAIL_PRESSURE", len: 2, converter: .uas(.pressureHighRangeTwoBytes)), // 0122
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.fuelRailGaugePressure, mnemonic: "FUEL_RAIL_GAUGE_PRESSURE", len: 2, converter: .uas(.pressureTenKPaTwoBytes)), // 0123
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.commandedEGR, mnemonic: "COMMANDED_EGR", len: 1, converter: .uas(.percentOneByte)), // 012C
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.egrError, mnemonic: "EGR_ERROR", len: 1, converter: .uas(.percentOneByteSigned)), // 012D
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.commandedEvaporativePurge, mnemonic: "COMMANDED_EVAP_PURGE", len: 1, converter: .uas(.percentOneByte)), // 012E
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.fuelLevelInput, mnemonic: "FUEL_LEVEL", len: 1, converter: .uas(.percentOneByte)), // 012F
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.warmupsSinceDTCCleared, mnemonic: "WARMUPS_SINCE_DTC_CLEARED", len: 1, converter: .uas(.countOneByte)), // 0130
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.distanceTraveledSinceDTCCleared, mnemonic: "DISTANCE_SINCE_DTC_CLEARED", len: 2, converter: .uas(.distanceTwoBytes)), // 0131
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.evapSystemVaporPressure, mnemonic: "EVAP_VAPOR_PRESSURE", len: 2, converter: .uas(.pressurePaSignedTwoBytes)), // 0132
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.barometricPressure, mnemonic: "BAROMETRIC_PRESSURE", len: 1, converter: .uas(.pressureKPaOneByte)), // 0133
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.catalystTemperatureBank1Sensor1, mnemonic: "CAT_TEMP_B1S1", len: 2, converter: .uas(.temperatureTwoBytes)), // 013C

            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.pids_40_5F, mnemonic: "PIDS_C", len: 4, converter: .pids(offset: 0x40)), // 0140
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.monitorStatusThisDriveCycle, mnemonic: "MONITOR_STATUS_THIS_CYCLE", len: 4, converter: .monitorStatusSinceDtcCleared), // 0141
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.controlModuleVoltage, mnemonic: "CONTROL_MODULE_VOLTAGE", len: 2, converter: .uas(.voltageTwoBytes)), // 0142
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.absoluteLoadValue, mnemonic: "ABSOLUTE_LOAD", len: 2, converter: .uas(.percentTwoBytes)), // 0143
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.commandedAirFuelEquivalenceRatio, mnemonic: "COMMANDED_EQUIV_RATIO", len: 2, converter: .uas(.ratioTwoBytes)), // 0144
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.relativeThrottlePosition, mnemonic: "RELATIVE_THROTTLE_POS", len: 1, converter: .uas(.percentOneByte)), // 0145
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.ambientAirTemperature, mnemonic: "AMBIENT_AIR_TEMP", len: 1, converter: .uas(.temperatureOneByte)), // 0146
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.absoluteThrottlePositionB, mnemonic: "ABS_THROTTLE_POS_B", len: 1, converter: .uas(.percentOneByte)), // 0147
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.absoluteThrottlePositionC, mnemonic: "ABS_THROTTLE_POS_C", len: 1, converter: .uas(.percentOneByte)), // 0148
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.acceleratorPedalPositionD, mnemonic: "ACCEL_PEDAL_POS_D", len: 1, converter: .uas(.percentOneByte)), // 0149
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.acceleratorPedalPositionE, mnemonic: "ACCEL_PEDAL_POS_E", len: 1, converter: .uas(.percentOneByte)), // 014A
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.acceleratorPedalPositionF, mnemonic: "ACCEL_PEDAL_POS_F", len: 1, converter: .uas(.percentOneByte)), // 014B
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.commandedThrottleActuator, mnemonic: "COMMANDED_THROTTLE_ACTUATOR", len: 1, converter: .uas(.percentOneByte)), // 014C
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.timeRunWithMILOn, mnemonic: "TIME_RUN_WITH_MIL_ON", len: 2, converter: .uas(.countTwoBytes)), // 014D
            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.timeSinceTroubleCodesCleared, mnemonic: "TIME_SINCE_DTC_CLEARED", len: 2, converter: .uas(.countTwoBytes)), // 014E

            MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.fuelType, mnemonic: "FUEL_TYPE", len: 1, converter: .localized),                                                               // 0152

            // 0x09
            MessageSpec(sid: ServiceId.vehicleInformation, pid: VehicleInformationType.vin, mnemonic: "VIN", len: 20, converter: .ascii(range: 2..<20))


            //MessageSpec(sid: ServiceId.currentPowertrainDiagnosticsData, pid: CurrentPowertrainDiagnosticsDataType.engineRPM, mnemonic: "ENGINE_RPM", converter: .uint8, unit: UnitTemperature.celsius)
        ]


    }
}

public extension UDS.OBD2 {

    struct MonitorStatusSinceDtcCleared {

        let milOn: Bool
        let dtcCount: Int
        let misfireMonitoringSupported: Bool
        let misfireMonitoringReady: Bool
        let comprehensiveComponentMonitoringSupported: Bool
        let comprehensiveComponentMonitoringReady: Bool
        let fuelSystemMonitoringSupported: Bool
        let fuelSystemMonitoringReady: Bool
        let hasCompressionIgnition: Bool
    }
}
