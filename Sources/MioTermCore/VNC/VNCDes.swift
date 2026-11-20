import CommonCrypto
import Foundation

/// RFB Security Type 2（VNC Authentication）专用的 DES 挑战-响应加密。
/// VNC 规范要求先将 8 字节口令密钥的每个字节按位反转，再以 DES-ECB 分别加密 16 字节随机挑战的两半。
public enum VNCDes {
    /// 使用明文口令对服务端发来的 16 字节随机挑战加密，返回 16 字节响应。
    public static func encryptChallenge(_ challenge: Data, password: String) -> Data {
        let key = vncKey(from: password)
        let reversedKey = Data(key.map(reverseBits))
        var output = Data(count: 16)

        for blockOffset in stride(from: 0, to: 16, by: 8) {
            let block = challenge.subdata(in: blockOffset..<(blockOffset + 8))
            var encrypted = [UInt8](repeating: 0, count: 8)
            var outLen = 0
            let status = reversedKey.withUnsafeBytes { keyPtr in
                block.withUnsafeBytes { inPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress,
                        kCCKeySizeDES,
                        nil,
                        inPtr.baseAddress,
                        8,
                        &encrypted,
                        8,
                        &outLen
                    )
                }
            }
            if status == kCCSuccess, outLen == 8 {
                output.replaceSubrange(blockOffset..<(blockOffset + 8), with: encrypted)
            }
        }
        return output
    }

    private static func vncKey(from password: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 8)
        let raw = Array(password.utf8)
        for index in 0..<min(8, raw.count) {
            bytes[index] = raw[index]
        }
        return bytes
    }

    private static func reverseBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var result: UInt8 = 0
        for _ in 0..<8 {
            result = (result << 1) | (input & 1)
            input >>= 1
        }
        return result
    }
}
