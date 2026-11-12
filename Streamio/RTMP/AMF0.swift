//
//  AMF0.swift
//  Streamio
//
//  Action Message Format 0 encoder/decoder used by RTMP command and data messages.
//  Objects keep their key order so command objects go over the wire exactly as written.
//

import Foundation

nonisolated public struct AMF0Property: Equatable, Sendable {
    public var key: String
    public var value: AMF0Value

    public init(_ key: String, _ value: AMF0Value) {
        self.key = key
        self.value = value
    }
}

nonisolated public indirect enum AMF0Value: Equatable, Sendable {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case object([AMF0Property])
    case null
    case undefined
    case ecmaArray([AMF0Property])
    case strictArray([AMF0Value])

    /// Looks up a property of an object or ECMA array.
    public subscript(key: String) -> AMF0Value? {
        switch self {
        case .object(let properties), .ecmaArray(let properties):
            properties.first { $0.key == key }?.value
        default:
            nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var numberValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }
}

nonisolated public enum AMF0 {
    private enum Marker: UInt8 {
        case number = 0x00
        case boolean = 0x01
        case string = 0x02
        case object = 0x03
        case null = 0x05
        case undefined = 0x06
        case reference = 0x07
        case ecmaArray = 0x08
        case objectEnd = 0x09
        case strictArray = 0x0A
        case date = 0x0B
        case longString = 0x0C
    }

    // MARK: Encoding

    public static func encode(_ values: [AMF0Value]) -> Data {
        var data = Data()
        for value in values {
            encode(value, into: &data)
        }
        return data
    }

    public static func encode(_ value: AMF0Value, into data: inout Data) {
        switch value {
        case .number(let number):
            data.append(Marker.number.rawValue)
            appendBigEndian(number.bitPattern, to: &data)

        case .boolean(let flag):
            data.append(Marker.boolean.rawValue)
            data.append(flag ? 0x01 : 0x00)

        case .string(let string):
            let utf8 = Data(string.utf8)
            if utf8.count > Int(UInt16.max) {
                data.append(Marker.longString.rawValue)
                appendBigEndian(UInt32(utf8.count), to: &data)
                data.append(utf8)
            } else {
                data.append(Marker.string.rawValue)
                appendShortString(utf8, to: &data)
            }

        case .object(let properties):
            data.append(Marker.object.rawValue)
            appendProperties(properties, to: &data)

        case .null:
            data.append(Marker.null.rawValue)

        case .undefined:
            data.append(Marker.undefined.rawValue)

        case .ecmaArray(let properties):
            data.append(Marker.ecmaArray.rawValue)
            appendBigEndian(UInt32(properties.count), to: &data)
            appendProperties(properties, to: &data)

        case .strictArray(let values):
            data.append(Marker.strictArray.rawValue)
            appendBigEndian(UInt32(values.count), to: &data)
            for element in values {
                encode(element, into: &data)
            }
        }
    }

    private static func appendProperties(_ properties: [AMF0Property], to data: inout Data) {
        for property in properties {
            appendShortString(Data(property.key.utf8), to: &data)
            encode(property.value, into: &data)
        }
        data.append(contentsOf: [0x00, 0x00, Marker.objectEnd.rawValue])
    }

    private static func appendShortString(_ utf8: Data, to data: inout Data) {
        let length = UInt16(min(utf8.count, Int(UInt16.max)))
        appendBigEndian(length, to: &data)
        data.append(utf8.prefix(Int(length)))
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    // MARK: Decoding

    /// Decodes every value in a command or data message payload.
    public static func decodeAll(_ data: Data) -> [AMF0Value] {
        let bytes = [UInt8](data)
        var offset = 0
        var values: [AMF0Value] = []
        while offset < bytes.count, let value = decodeValue(bytes, &offset) {
            values.append(value)
        }
        return values
    }

    /// Decodes a single value starting at `offset`, advancing it past the value.
    public static func decode(data: Data, offset: inout Int) -> AMF0Value? {
        let bytes = [UInt8](data)
        return decodeValue(bytes, &offset)
    }

    private static func decodeValue(_ bytes: [UInt8], _ offset: inout Int) -> AMF0Value? {
        guard offset < bytes.count, let marker = Marker(rawValue: bytes[offset]) else { return nil }
        offset += 1

        switch marker {
        case .number:
            guard let bits = readInteger(UInt64.self, bytes, &offset) else { return nil }
            return .number(Double(bitPattern: bits))

        case .boolean:
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return .boolean(bytes[offset] != 0)

        case .string:
            guard let string = readShortString(bytes, &offset) else { return nil }
            return .string(string)

        case .longString:
            guard let length = readInteger(UInt32.self, bytes, &offset),
                  offset + Int(length) <= bytes.count else { return nil }
            let string = String(decoding: bytes[offset..<offset + Int(length)], as: UTF8.self)
            offset += Int(length)
            return .string(string)

        case .object:
            guard let properties = readProperties(bytes, &offset) else { return nil }
            return .object(properties)

        case .null:
            return .null

        case .undefined:
            return .undefined

        case .reference:
            // References are not used by RTMP servers in practice; skip the 2-byte index.
            offset += 2
            return .undefined

        case .ecmaArray:
            guard readInteger(UInt32.self, bytes, &offset) != nil,
                  let properties = readProperties(bytes, &offset) else { return nil }
            return .ecmaArray(properties)

        case .strictArray:
            guard let count = readInteger(UInt32.self, bytes, &offset) else { return nil }
            var values: [AMF0Value] = []
            for _ in 0..<count {
                guard let value = decodeValue(bytes, &offset) else { return nil }
                values.append(value)
            }
            return .strictArray(values)

        case .date:
            // 8-byte double milliseconds + 2-byte timezone.
            guard let bits = readInteger(UInt64.self, bytes, &offset) else { return nil }
            offset += 2
            return .number(Double(bitPattern: bits))

        case .objectEnd:
            return nil
        }
    }

    private static func readProperties(_ bytes: [UInt8], _ offset: inout Int) -> [AMF0Property]? {
        var properties: [AMF0Property] = []
        while offset + 3 <= bytes.count {
            if bytes[offset] == 0x00, bytes[offset + 1] == 0x00, bytes[offset + 2] == Marker.objectEnd.rawValue {
                offset += 3
                return properties
            }
            guard let key = readShortString(bytes, &offset),
                  let value = decodeValue(bytes, &offset) else { return nil }
            properties.append(AMF0Property(key, value))
        }
        return nil
    }

    private static func readShortString(_ bytes: [UInt8], _ offset: inout Int) -> String? {
        guard let length = readInteger(UInt16.self, bytes, &offset),
              offset + Int(length) <= bytes.count else { return nil }
        let string = String(decoding: bytes[offset..<offset + Int(length)], as: UTF8.self)
        offset += Int(length)
        return string
    }

    private static func readInteger<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], _ offset: inout Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= bytes.count else { return nil }
        var value: T = 0
        for index in 0..<size {
            value = (value << 8) | T(bytes[offset + index])
        }
        offset += size
        return value
    }
}
