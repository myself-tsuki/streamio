//
//  AMF0.swift
//  Streamio
//

import Foundation

public enum AMF0Value: Equatable, Sendable {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case object([String: AMF0Value])
    case null
    case ecmaArray([String: AMF0Value])
    case endOfObject
}

public struct AMF0 {
    public static func encode(_ value: AMF0Value) -> Data {
        var data = Data()
        encode(value, into: &data)
        return data
    }

    public static func encode(_ value: AMF0Value, into data: inout Data) {
        switch value {
        case .number(let num):
            data.append(0x00) // Number marker
            var bits = num.bitPattern.bigEndian
            data.append(Data(bytes: &bits, count: 8))

        case .boolean(let bool):
            data.append(0x01) // Boolean marker
            data.append(bool ? 0x01 : 0x00)

        case .string(let str):
            data.append(0x02) // String marker
            encodeShortString(str, into: &data)

        case .object(let dict):
            data.append(0x03) // Object marker
            for (key, val) in dict {
                encodeShortString(key, into: &data)
                encode(val, into: &data)
            }
            // End of object: empty string (0x0000) + 0x09
            data.append(contentsOf: [0x00, 0x00, 0x09])

        case .null:
            data.append(0x05) // Null marker

        case .ecmaArray(let dict):
            data.append(0x08) // ECMA array marker
            var count = UInt32(dict.count).bigEndian
            data.append(Data(bytes: &count, count: 4))
            for (key, val) in dict {
                encodeShortString(key, into: &data)
                encode(val, into: &data)
            }
            // End of object marker
            data.append(contentsOf: [0x00, 0x00, 0x09])

        case .endOfObject:
            data.append(contentsOf: [0x00, 0x00, 0x09])
        }
    }

    private static func encodeShortString(_ str: String, into data: inout Data) {
        let utf8 = Data(str.utf8)
        var length = UInt16(min(utf8.count, 65535)).bigEndian
        data.append(Data(bytes: &length, count: 2))
        data.append(utf8)
    }

    public static func decode(data: Data, offset: inout Int) -> AMF0Value? {
        guard offset < data.count else { return nil }
        let marker = data[offset]
        offset += 1

        switch marker {
        case 0x00: // Number
            guard offset + 8 <= data.count else { return nil }
            let sub = data.subdata(in: offset..<(offset + 8))
            offset += 8
            let bitPattern = sub.withUnsafeBytes { $0.load(as: UInt64.self) }.bigEndian
            return .number(Double(bitPattern: bitPattern))

        case 0x01: // Boolean
            guard offset < data.count else { return nil }
            let boolVal = data[offset] != 0
            offset += 1
            return .boolean(boolVal)

        case 0x02: // String
            return decodeShortString(data: data, offset: &offset).map { .string($0) }

        case 0x03: // Object
            var dict: [String: AMF0Value] = [:]
            while offset < data.count {
                // Check for object end: 0x00 0x00 0x09
                if offset + 2 < data.count && data[offset] == 0x00 && data[offset + 1] == 0x00 && data[offset + 2] == 0x09 {
                    offset += 3
                    break
                }
                guard let key = decodeShortString(data: data, offset: &offset),
                      let val = decode(data: data, offset: &offset) else {
                    break
                }
                dict[key] = val
            }
            return .object(dict)

        case 0x05: // Null
            return .null

        case 0x08: // ECMA Array
            guard offset + 4 <= data.count else { return nil }
            offset += 4 // skip count
            var dict: [String: AMF0Value] = [:]
            while offset < data.count {
                if offset + 2 < data.count && data[offset] == 0x00 && data[offset + 1] == 0x00 && data[offset + 2] == 0x09 {
                    offset += 3
                    break
                }
                guard let key = decodeShortString(data: data, offset: &offset),
                      let val = decode(data: data, offset: &offset) else {
                    break
                }
                dict[key] = val
            }
            return .ecmaArray(dict)

        default:
            return nil
        }
    }

    private static func decodeShortString(data: Data, offset: inout Int) -> String? {
        guard offset + 2 <= data.count else { return nil }
        let sub = data.subdata(in: offset..<(offset + 2))
        offset += 2
        let length = Int(sub.withUnsafeBytes { $0.load(as: UInt16.self) }.bigEndian)
        guard offset + length <= data.count else { return nil }
        let strData = data.subdata(in: offset..<(offset + length))
        offset += length
        return String(data: strData, encoding: .utf8)
    }
}

