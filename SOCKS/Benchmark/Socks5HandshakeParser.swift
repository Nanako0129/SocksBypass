import Foundation

struct Socks5HandshakeParser {
    static let maximumFeedBytes = 64 * 1024

    struct Target: Equatable {
        let address: String
        let port: UInt16
    }

    struct ConnectRequest: Equatable {
        let target: Target
        let firstPayload: Data
    }

    struct Output: Equatable {
        var replies: [Data] = []
        var connect: ConnectRequest?
        var shouldClose = false
    }

    private enum Phase {
        case greetingHeader
        case greetingMethods(Int)
        case requestHeader
        case requestIPv4Body
        case active
        case closed
    }

    private var phase = Phase.greetingHeader
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

        while offset < data.count, !output.shouldClose, output.connect == nil {
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
                } else if bytes[1] != 0x01 {
                    reply = 0x07
                } else if bytes[3] != 0x01 {
                    reply = 0x08
                } else {
                    reply = nil
                }

                if let reply {
                    output.replies.append(Self.requestReply(reply))
                    close(&output)
                } else {
                    phase = .requestIPv4Body
                }

            case .requestIPv4Body:
                guard appendNeeded(6, from: data, offset: &offset) else { break }
                let bytes = [UInt8](buffer)
                buffer.removeAll(keepingCapacity: true)

                let address = "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
                let port = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
                let payloadStart = data.index(data.startIndex, offsetBy: offset)
                let payload = Data(data[payloadStart..<data.endIndex])
                offset = data.count
                phase = .active
                output.connect = ConnectRequest(
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
        case .requestHeader, .requestIPv4Body:
            output.replies.append(Self.requestReply(0x01))
        case .active, .closed:
            break
        }
        close(&output)
        return output
    }
}
