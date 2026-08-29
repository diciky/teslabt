import Foundation
import zlib

/// 用户数据备份文件（.bin）的打包与校验，兼容原版小智 Flasher。
///
/// 存 VIN、私钥、配对标志三样。私钥是唯一不可再生的部分——
/// 它对应的公钥在车辆白名单里，丢了就得开车去重新刷 NFC 钥匙卡。
///
/// 格式（小端）：
///   偏移 0   magic  "WMBK"        4 B
///         4   version u16 = 1      2 B
///         6   flags   u16          2 B   bit0 = paired
///         8   vin_len u16          2 B
///        10   key_len u16          2 B
///        12   crc32   u32          4 B   覆盖其后的 vin+key 原始字节
///        16   保留    u32          4 B
///        20   vin 字节
///        ..   私钥 PEM 字节
struct BackupPayload {
    var vin: String?
    var privateKeyPEM: String
    var paired: Bool
}

enum BackupError: Error, LocalizedError {
    case noPrivateKey
    case noVin
    case tooSmall
    case badMagic
    case badVersion
    case truncated
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .noPrivateKey: return "没有私钥可备份"
        case .noVin: return "没有 VIN 可备份"
        case .tooSmall: return "文件太小，不是有效的备份"
        case .badMagic: return "文件头不匹配，这不是本工具生成的备份"
        case .badVersion: return "备份版本不受支持"
        case .truncated: return "文件被截断，内容不完整"
        case .checksumMismatch: return "校验和不符，文件已损坏"
        }
    }
}

enum Backup {
    static let magic = "WMBK".data(using: .ascii)!
    static let version: UInt16 = 1
    static let headerSize = 20

    static func defaultFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        return "bak_\(df.string(from: Date())).bin"
    }

    /// 打包备份数据
    static func pack(_ p: BackupPayload) throws -> Data {
        guard !p.privateKeyPEM.isEmpty else { throw BackupError.noPrivateKey }
        guard let vin = p.vin, !vin.isEmpty else { throw BackupError.noVin }

        let vinData = vin.data(using: .ascii)!
        let keyData = p.privateKeyPEM.data(using: .utf8)!
        let body = vinData + keyData

        var header = Data()
        header.append(magic)
        appendU16(version, to: &header)
        appendU16(p.paired ? 1 : 0, to: &header)
        appendU16(UInt16(vinData.count), to: &header)
        appendU16(UInt16(keyData.count), to: &header)
        appendU32(Backup.zlibCrc32(body), to: &header)
        appendU32(0, to: &header)
        return header + body
    }

    /// 解析并校验备份
    static func unpack(_ data: Data) throws -> BackupPayload {
        guard data.count >= headerSize else { throw BackupError.tooSmall }
        let h = [UInt8](data.prefix(headerSize))
        let magicBytes = Array(h[0..<4])
        guard magicBytes == Array(magic) else { throw BackupError.badMagic }

        let version = readU16(h, 4)
        guard version == self.version else { throw BackupError.badVersion }
        let flags = readU16(h, 6)
        let vinLen = Int(readU16(h, 8))
        let keyLen = Int(readU16(h, 10))
        let storedCrc = readU32(h, 12)

        let end = headerSize + vinLen + keyLen
        guard data.count >= end else { throw BackupError.truncated }
        let body = data.subdata(in: headerSize..<end)
        guard zlibCrc32(body) == storedCrc else { throw BackupError.checksumMismatch }

        let vin = String(data: body.subdata(in: 0..<vinLen), encoding: .ascii)
        let key = String(data: body.subdata(in: vinLen..<end), encoding: .utf8) ?? ""
        return BackupPayload(vin: vin, privateKeyPEM: key, paired: (flags & 1) == 1)
    }

    // MARK: - Helpers

    static func appendU16(_ v: UInt16, to data: inout Data) {
        var v = v
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    static func appendU32(_ v: UInt32, to data: inout Data) {
        var v = v
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
    static func readU16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset+1]) << 8)
    }
    static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset+1]) << 8)
            | (UInt32(bytes[offset+2]) << 16) | (UInt32(bytes[offset+3]) << 24)
    }

    /// zlib CRC32
    static func zlibCrc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buf in
            var crc: uLong = crc32(0, nil, 0)
            crc = crc32(crc, buf.bindMemory(to: UInt8.self).baseAddress, uInt(data.count))
            return UInt32(crc & 0xFFFFFFFF)
        }
    }
}
