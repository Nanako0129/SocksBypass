import Foundation
import XCTest

final class Socks5HandshakeParserTests: XCTestCase {
    private let greeting = Data([0x05, 0x01, 0x00])
    private let request = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x1F, 0x90])

    func testGreetingEverySplitPoint() {
        for split in 0...greeting.count {
            var parser = Socks5HandshakeParser()
            let first = parser.feed(Data(greeting.prefix(split)))
            let second = parser.feed(Data(greeting.dropFirst(split)))
            XCTAssertEqual(first.replies + second.replies, [Data([0x05, 0x00])], "split \(split)")
            XCTAssertFalse(parser.isClosed, "split \(split)")
        }
    }

    func testRequestEverySplitPoint() {
        for split in 0...request.count {
            var parser = Socks5HandshakeParser()
            _ = parser.feed(greeting)
            let first = parser.feed(Data(request.prefix(split)))
            let second = parser.feed(Data(request.dropFirst(split)))
            let connect = first.connect ?? second.connect
            XCTAssertEqual(connect?.target, .init(address: "127.0.0.1", port: 8080), "split \(split)")
            XCTAssertEqual(connect?.firstPayload, Data(), "split \(split)")
        }
    }

    func testGreetingAndRequestOneByteAtATime() {
        var parser = Socks5HandshakeParser()
        var replies: [Data] = []
        var connect: Socks5HandshakeParser.ConnectRequest?

        for byte in greeting + request {
            let output = parser.feed(Data([byte]))
            replies.append(contentsOf: output.replies)
            connect = output.connect ?? connect
        }

        XCTAssertEqual(replies, [Data([0x05, 0x00])])
        XCTAssertEqual(connect?.target, .init(address: "127.0.0.1", port: 8080))
        XCTAssertTrue(parser.isActive)
    }

    func testFullyCoalescedHandshakePreservesFirstPayload() {
        var parser = Socks5HandshakeParser()
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF])
        let output = parser.feed(greeting + request + payload)

        XCTAssertEqual(output.replies, [Data([0x05, 0x00])])
        XCTAssertEqual(output.connect?.target, .init(address: "127.0.0.1", port: 8080))
        XCTAssertEqual(output.connect?.firstPayload, payload)
    }

    func testValidRequestWaitsForAllTenBytes() {
        var parser = Socks5HandshakeParser()
        _ = parser.feed(greeting)
        XCTAssertNil(parser.feed(Data(request.prefix(9))).connect)
        XCTAssertEqual(parser.bufferedByteCount, 5)
        XCTAssertNotNil(parser.feed(Data(request.suffix(1))).connect)
    }

    func testInvalidGreetingVersionRepliesAndCloses() {
        var parser = Socks5HandshakeParser()
        let output = parser.feed(Data([0x04, 0x01, 0x00]))
        XCTAssertEqual(output.replies, [Data([0x05, 0xFF])])
        XCTAssertTrue(output.shouldClose)
        XCTAssertTrue(parser.isClosed)
    }

    func testUsernamePasswordOnlyDoesNotConsumeTrailingCredentialBytes() {
        var parser = Socks5HandshakeParser()
        let credentialShapedBytes = Data([0x01, 0x08]) + Data("username".utf8) + Data([0x08]) + Data("password".utf8)
        let output = parser.feed(Data([0x05, 0x01, 0x02]) + credentialShapedBytes)

        XCTAssertEqual(output.replies, [Data([0x05, 0xFF])])
        XCTAssertTrue(output.shouldClose)
        XCTAssertTrue(parser.isClosed)
        XCTAssertEqual(parser.bufferedByteCount, 0)
        XCTAssertEqual(parser.feed(credentialShapedBytes), .init())
    }

    func testNMETHODS255WaitsForCompleteFrame() {
        var methods = Data(repeating: 0x02, count: 255)
        methods[methods.index(before: methods.endIndex)] = 0x00
        let frame = Data([0x05, 0xFF]) + methods
        var parser = Socks5HandshakeParser()

        let truncated = parser.feed(Data(frame.dropLast()))
        XCTAssertTrue(truncated.replies.isEmpty)
        XCTAssertFalse(parser.isClosed)
        XCTAssertEqual(parser.bufferedByteCount, 254)

        let complete = parser.feed(Data(frame.suffix(1)))
        XCTAssertEqual(complete.replies, [Data([0x05, 0x00])])
        XCTAssertFalse(parser.isClosed)
    }

    func testNMETHODS255TruncatedEOFClosesWithoutCrash() {
        var parser = Socks5HandshakeParser()
        let truncated = Data([0x05, 0xFF]) + Data(repeating: 0x02, count: 254)
        XCTAssertTrue(parser.feed(truncated).replies.isEmpty)
        XCTAssertTrue(parser.finish().shouldClose)
        XCTAssertTrue(parser.isClosed)
    }

    func testInvalidRequestFieldsUseRFCReplyCodes() {
        assertInvalidRequest(header: [0x04, 0x01, 0x00, 0x01], reply: 0x01)
        assertInvalidRequest(header: [0x05, 0x01, 0x01, 0x01], reply: 0x01)
        assertInvalidRequest(header: [0x05, 0x02, 0x00, 0x01], reply: 0x07)
        assertInvalidRequest(header: [0x05, 0x01, 0x00, 0x03], reply: 0x08)
    }

    func testOversizedHandshakeFeedFailsClosed() {
        var parser = Socks5HandshakeParser()
        let output = parser.feed(Data(repeating: 0x00, count: Socks5HandshakeParser.maximumFeedBytes + 1))
        XCTAssertEqual(output.replies, [Data([0x05, 0xFF])])
        XCTAssertTrue(output.shouldClose)
        XCTAssertTrue(parser.isClosed)
    }

    private func assertInvalidRequest(header: [UInt8], reply: UInt8) {
        var parser = Socks5HandshakeParser()
        _ = parser.feed(greeting)
        let output = parser.feed(Data(header))
        XCTAssertEqual(output.replies, [Socks5HandshakeParser.requestReply(reply)])
        XCTAssertTrue(output.shouldClose)
        XCTAssertTrue(parser.isClosed)
    }
}
