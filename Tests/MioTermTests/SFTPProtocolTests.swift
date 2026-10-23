import Foundation
import Testing
@testable import MioTermCore

/// 报文编解码、拆帧与远端路径词法。这些是纯函数，先把它们钉死，
/// 上面的连接与客户端才有可信的地基。
struct SFTPProtocolTests {
    /// 报文编号就是协议本身：一位写错，服务端会把 RENAME 当 MKDIR 执行，
    /// 而内存假服务端用同一张表，跟着一起错，全套用例照样绿。
    /// 这份对照直接抄 draft-ietf-secsh-filexfer-02，是唯一可信的来源。
    @Test func packetTypeNumbersMatchDraft02() {
        let expected: [(SFTPPacketType, UInt8)] = [
            (.initialize, 1), (.version, 2),
            (.open, 3), (.close, 4), (.read, 5), (.write, 6),
            (.lstat, 7), (.fstat, 8), (.setstat, 9), (.fsetstat, 10),
            (.openDir, 11), (.readDir, 12), (.remove, 13),
            (.mkdir, 14), (.rmdir, 15), (.realpath, 16), (.stat, 17), (.rename, 18),
            (.badMessage, 100), (.status, 101), (.handle, 102), (.data, 103), (.name, 104), (.attrs, 105),
            (.extended, 200), (.extendedReply, 201)
        ]
        for (type, number) in expected {
            #expect(type.rawValue == number, "\(type) 的编号应为 \(number)")
            #expect(SFTPPacketType(rawValue: number) == type, "\(number) 号报文应解成 \(type)")
        }
    }

    @Test func writerReaderRoundTrip() throws {
        var writer = SFTPWriter()
        writer.uint8(7)
        writer.uint32(0xDEAD_BEEF)
        writer.uint64(0x0000_0001_FFFF_FFFF)
        writer.string("你好 sftp")
        writer.bytes(Data([1, 2, 3]))

        var reader = SFTPReader(writer.data)
        #expect(try reader.uint8() == 7)
        #expect(try reader.uint32() == 0xDEAD_BEEF)
        #expect(try reader.uint64() == 0x0000_0001_FFFF_FFFF)
        #expect(try reader.string() == "你好 sftp")
        #expect(try reader.bytes() == Data([1, 2, 3]))
        #expect(reader.isAtEnd)
    }

    @Test func readerReportsShortage() throws {
        var short = SFTPReader(Data([0x00, 0x01]))
        #expect((try? short.uint32()) == nil)
        var truncatedString = SFTPReader(Data([0x00, 0x00, 0x00, 0x08, 0x41]))
        #expect((try? truncatedString.string()) == nil)
        var validString = SFTPReader(Data([0x00, 0x00, 0x00, 0x01, 0x41]))
        #expect(try validString.string() == "A")
    }

    @Test func assemblerHandlesPartialAndMultipleFrames() throws {
        let first = SFTPCodec.frame(type: .status, id: 1) { $0.uint32(0) }
        let second = SFTPCodec.frame(type: .handle, id: 2) { $0.bytes(Data("h".utf8)) }
        var assembler = SFTPFrameAssembler()

        // 半截帧：不该吐出任何东西
        let head = first.prefix(3)
        #expect(try assembler.feed(Data(head)).isEmpty)

        let tail = Data(first.dropFirst(3)) + second
        let packets = try assembler.feed(tail)
        #expect(packets.count == 2)
        #expect(packets[0].type == .status)
        #expect(packets[0].id == 1)
        #expect(packets[0].payload == Data([0, 0, 0, 0]))
        #expect(packets[1].type == .handle)
        var handleReader = SFTPReader(packets[1].payload)
        #expect(try handleReader.bytes() == Data("h".utf8))
    }

    @Test func assemblerRejectsAbsurdLength() {
        var junk = SFTPWriter()
        junk.uint32(8_000_000)
        var assembler = SFTPFrameAssembler()
        #expect(throws: SFTPCodecError.self) {
            _ = try assembler.feed(junk.data + Data(repeating: 0, count: 16))
        }
    }

    @Test func frameLayoutMatchesSpecification() {
        let frame = SFTPCodec.frame(type: .remove, id: 9) { $0.string("/tmp/a") }
        // 长度 = 类型 1 + 请求号 4 + 字符串(4 + 6)
        #expect(frame.count == 4 + 1 + 4 + 4 + 6)
        #expect(frame.withUnsafeBytes { Int(UInt32(bigEndian: $0.load(as: UInt32.self))) } == frame.count - 4)
        #expect(frame[4] == SFTPPacketType.remove.rawValue)
    }

    @Test func initializePacketCarriesVersionThree() {
        let packet = SFTPCodec.initializePacket()
        #expect(packet.count == 9)
        #expect(packet[4] == SFTPPacketType.initialize.rawValue)
        #expect(packet.subdata(in: 5..<9).withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) } == 3)
    }

    @Test func pathNormalizationMatchesGoPathClean() {
        #expect(SFTPPath.normalize("/usr//local/../bin/") == "/usr/bin")
        #expect(SFTPPath.normalize("/a/./b") == "/a/b")
        #expect(SFTPPath.normalize("//") == "/")
        #expect(SFTPPath.normalize("/..") == "/")
        #expect(SFTPPath.normalize("/../a") == "/a")
        #expect(SFTPPath.normalize("") == ".")
        #expect(SFTPPath.normalize(".") == ".")
        #expect(SFTPPath.normalize("a/../../b") == "../b")
    }

    @Test func pathJoinKeepsRootSane() {
        #expect(SFTPPath.join("/", "etc") == "/etc")
        #expect(SFTPPath.join("/var", "log") == "/var/log")
        #expect(SFTPPath.join("/var/", "/abs.txt") == "/abs.txt")
        #expect(SFTPPath.join("/home/user", "..") == "/home")
    }

    @Test func pathParentAndAncestors() {
        #expect(SFTPPath.parent("/usr/local/bin") == "/usr/local")
        #expect(SFTPPath.parent("/usr") == "/")
        #expect(SFTPPath.parent("/") == "/")
        #expect(SFTPPath.parent("relative") == ".")
        #expect(SFTPPath.lastComponent("/var/log/app.log") == "app.log")
        #expect(SFTPPath.ancestors("/usr/local/bin") == ["/", "/usr", "/usr/local", "/usr/local/bin"])
        #expect(SFTPPath.isRoot("/"))
        #expect(!SFTPPath.isRoot("/home"))
    }

    @Test func attributesEncodeOnlyFlaggedFields() throws {
        var attributes = SFTPFileAttributes()
        attributes.flags = [.size, .permissions]
        attributes.size = 4_096
        attributes.permissions = 0o100644

        var writer = SFTPWriter()
        attributes.encode(into: &writer)
        // flags(4) + size(8) + mode(4)
        #expect(writer.data.count == 16)

        var reader = SFTPReader(writer.data)
        let decoded = try SFTPFileAttributes.decoding(&reader)
        #expect(decoded == attributes)
        #expect(decoded.isDirectory == false)
        #expect(reader.isAtEnd)
    }

    @Test func directoryFlagComesFromModeBits() {
        var mode = SFTPFileAttributes()
        mode.flags = [.permissions]
        mode.permissions = 0o040755
        #expect(mode.isDirectory)

        var missingMode = SFTPFileAttributes()
        missingMode.permissions = 0o040755
        #expect(!missingMode.isDirectory)
    }

    @Test func replyParsesNameEntries() throws {
        var attributes = SFTPFileAttributes()
        attributes.flags = [.size, .times, .permissions]
        attributes.size = 12
        attributes.permissions = 0o100600
        attributes.modificationTime = 1_700_000_000

        var body = SFTPWriter()
        body.uint32(1)
        // 线上顺序：文件名字段在前，ls -l 长名在后（draft-ietf-secsh-filexfer-02 §5）
        body.string("conf")
        body.string("-rw------- 1 u g 12 Jan 1 2024 conf")
        attributes.encode(into: &body)

        let packet = SFTPPacket(type: .name, id: 0, payload: body.data)
        let reply = try SFTPReply(packet: packet)
        guard case .name(let entries) = reply else { Issue.record("应为 name 应答"); return }
        #expect(entries.count == 1)
        #expect(entries[0].shortName == "conf")
        #expect(entries[0].longName == "-rw------- 1 u g 12 Jan 1 2024 conf")
        #expect(entries[0].size == 12)
        #expect(entries[0].isDirectory == false)
        #expect(entries[0].modificationTime == Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// 目录里有一个非 UTF-8 的历史文件名时，不能连累整层目录都读不出来。
    @Test func nameEntryWithNonUTF8BytesStillParses() throws {
        var attributes = SFTPFileAttributes()
        attributes.flags = [.size]
        attributes.size = 1

        var body = SFTPWriter()
        body.uint32(1)
        body.bytes(Data([0x62, 0x61, 0x64, 0xFF]))
        body.string("bad?")
        attributes.encode(into: &body)

        let packet = SFTPPacket(type: .name, id: 0, payload: body.data)
        let reply = try SFTPReply(packet: packet)
        guard case .name(let entries) = reply else { Issue.record("应为 name 应答"); return }
        #expect(entries.count == 1)
        #expect(entries[0].shortName.hasPrefix("bad"))
        #expect(entries[0].size == 1)
    }

    @Test func replyTurnsNonOKStatusIntoError() throws {
        var body = SFTPWriter()
        body.uint32(SFTPStatusCode.permissionDenied.rawValue)
        body.string("Permission denied")
        body.string("zh")
        let packet = SFTPPacket(type: .status, id: 3, payload: body.data)
        let reply = try SFTPReply(packet: packet)
        #expect(throws: SFTPStatusError(code: .permissionDenied, message: "Permission denied")) {
            try reply.requireOK()
        }
        #expect(reply.statusCode == .permissionDenied)
    }

    @Test func hiddenFilterKeepsDotsOutOfTheBrowser() {
        func entry(_ name: String) -> SFTPDirectoryEntry {
            SFTPDirectoryEntry(longName: name, shortName: name, attributes: SFTPFileAttributes())
        }
        let entries = [entry("."), entry(".."), entry(".ssh"), entry("logs")]
        #expect(SFTPDirectoryFilter.entries(entries, showHidden: false).map(\.shortName) == ["logs"])
        // 显示点文件也不该把 . 与 .. 当条目列出来
        #expect(SFTPDirectoryFilter.entries(entries, showHidden: true).map(\.shortName) == [".ssh", "logs"])
    }

    @Test func dotEntriesAreMarkedHiddenForDimming() {
        func file(_ name: String) -> SFTPFileEntry {
            SFTPFileEntry(path: "/home/user/\(name)", name: name, isDirectory: false, size: 0, modifiedAt: nil)
        }
        #expect(file(".bashrc").isHidden)
        #expect(file(".config").isHidden)
        #expect(!file("README.md").isHidden)
        #expect(!file("logs").isHidden)
    }
}
