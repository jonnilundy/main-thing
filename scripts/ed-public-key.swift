// Reads a Sparkle EdDSA private key (base64 of the 32 byte Ed25519 seed) on stdin and prints its
// public key in base64, the form SUPublicEDKey takes. release.sh uses it to refuse a signing key
// that does not match the app. The private key never reaches stdout or stderr.
import CryptoKit
import Foundation

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: input), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    FileHandle.standardError.write(Data("ed-public-key: stdin is not base64 of a 32 byte Ed25519 seed\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
