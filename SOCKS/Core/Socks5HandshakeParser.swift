import Foundation

struct Socks5HandshakeParser {
    static let maximumFeedBytes = 64 * 1024

    struct Target: Equatable {
        let address: String
        let port: UInt16
    }

    enum Command: Equatable {
        case connect
        case udpAssociate
    }

    struct Request: Equatable {
        let command: Command
        /// For CONNECT the destination. For UDP ASSOCIATE the address the client
        /// expects to send datagrams from, which is conventionally 0.0.0.0:0.
        let target: Target
        let firstPayload: Data
    }

    struct Output: Equatable {
        var replies: [Data] = []
        var request: Request?
        var shouldClose = false
    }

    private enum AddressKind {
        case ipv4
        case ipv6
        case domain
    }

    private enum Phase {
        case greetingHeader
        case greetingMethods(Int)
        case requestHeader
        case requestDomainLength
        /// Address kind plus the byte count still to read: address bytes and the port.
        case requestAddress(AddressKind, Int)
        case active
        case closed
    }

    private var phase = Phase.greetingHeader
    private var pendingCommand = Command.connect
    private var buffer = Data()

    var isActive: Bool {
        if case .active = phase { return true }
        return false
    }

    var isClosed: Bool {
        if case .closed = phase { return true }
        return false
    }

    var bufferedByteCount: Int {
        buffer.count
    }

    mutating func feed(_ data: Data) -> Output {
        guard data.count <= Self.maximumFeedBytes else {
            return closeForOversizedFeed()
        }
        guard !data.isEmpty, !isClosed else { return Output() }

        var output = Output()
        var offset = 0

        while offset < data.count, !output.shouldClose, output.request == nil {
            switch phase {
            case .greetingHeader:
                guard appendNeeded(2, from: data, offset: &offset) else { break }
                let version = buffer[buffer.startIndex]
                let methodCount = Int(buffer[buffer.index(after: buffer.startIndex)])
                buffer.removeAll(keepingCapacity: true)

                guard version == 0x05, methodCount > 0 else {
                    output.replies.append(Data([0x05, 0xFF]))
                    close(&output)
                    continue
                }
                phase = .greetingMethods(methodCount)

            case .greetingMethods(let methodCount):
                guard appendNeeded(methodCount, from: data, offset: &offset) else { break }
                let supportsNoAuth = buffer.contains(0x00)
                buffer.removeAll(keepingCapacity: true)

                guard supportsNoAuth else {
                    output.replies.append(Data([0x05, 0xFF]))
                    close(&output)
                    continue
                }
                output.replies.append(Data([0x05, 0x00]))
                phase = .requestHeader

            case .requestHeader:
                guard appendNeeded(4, from: data, offset: &offset) else { break }
                let bytes = [UInt8](buffer)
                buffer.removeAll(keepingCapacity: true)

                let reply: UInt8?
                if bytes[0] != 0x05 {
                    reply = 0x01
                } else if bytes[2] != 0x00 {
                    reply = 0x01
                } else if bytes[1] != 0x01, bytes[1] != 0x03 {
                    reply = 0x07
                } else {
                    reply = nil
                }
                let command: Command = bytes[1] == 0x03 ? .udpAssociate : .connect

                if let reply {
                    output.replies.append(Self.requestReply(reply))
                    close(&output)
                } else {
                    pendingCommand = command
                    switch bytes[3] {
                    case 0x01:
                        phase = .requestAddress(.ipv4, 6)
                    case 0x04:
                        phase = .requestAddress(.ipv6, 18)
                    case 0x03:
                        phase = .requestDomainLength
                    default:
                        output.replies.append(Self.requestReply(0x08))
                        close(&output)
                    }
                }

            case .requestDomainLength:
                guard appendNeeded(1, from: data, offset: &offset) else { break }
                let length = Int(buffer[buffer.startIndex])
                buffer.removeAll(keepingCapacity: true)

                guard length > 0 else {
                    output.replies.append(Self.requestReply(0x01))
                    close(&output)
                    continue
                }
                phase = .requestAddress(.domain, length + 2)

            case .requestAddress(let kind, let required):
                guard appendNeeded(required, from: data, offset: &offset) else { break }
                let bytes = [UInt8](buffer)
                buffer.removeAll(keepingCapacity: true)

                let address = Self.address(kind, from: bytes.dropLast(2))
                let port = UInt16(bytes[required - 2]) << 8 | UInt16(bytes[required - 1])
                let payloadStart = data.index(data.startIndex, offsetBy: offset)
                let payload = Data(data[payloadStart..<data.endIndex])
                offset = data.count
                phase = .active
                output.request = Request(
                    command: pendingCommand,
                    target: Target(address: address, port: port),
                    firstPayload: payload
                )

            case .active:
                offset = data.count

            case .closed:
                offset = data.count
            }
        }

        return output
    }

    mutating func finish() -> Output {
        guard !isClosed, !isActive else { return Output() }
        buffer.removeAll(keepingCapacity: false)
        phase = .closed
        return Output(shouldClose: true)
    }

    static func requestReply(_ reply: UInt8) -> Data {
        Data([0x05, reply, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    private static func address(_ kind: AddressKind, from bytes: ArraySlice<UInt8>) -> String {
        switch kind {
        case .ipv4:
            return bytes.map(String.init).joined(separator: ".")
        case .ipv6:
            // Uncompressed form; NWEndpoint.Host parses it and callers never display it.
            return stride(from: bytes.startIndex, to: bytes.endIndex, by: 2)
                .map { String(format: "%02x%02x", bytes[$0], bytes[$0 + 1]) }
                .joined(separator: ":")
        case .domain:
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private mutating func appendNeeded(_ requiredCount: Int, from data: Data, offset: inout Int) -> Bool {
        let needed = requiredCount - buffer.count
        guard needed > 0 else { return true }

        let available = data.count - offset
        let count = min(needed, available)
        guard count > 0 else { return false }

        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        buffer.append(contentsOf: data[start..<end])
        offset += count
        return buffer.count == requiredCount
    }

    private mutating func close(_ output: inout Output) {
        buffer.removeAll(keepingCapacity: false)
        phase = .closed
        output.shouldClose = true
    }

    private mutating func closeForOversizedFeed() -> Output {
        var output = Output()
        switch phase {
        case .greetingHeader, .greetingMethods:
            output.replies.append(Data([0x05, 0xFF]))
        case .requestHeader, .requestDomainLength, .requestAddress:
            output.replies.append(Self.requestReply(0x01))
        case .active, .closed:
            break
        }
        close(&output)
        return output
    }
}
