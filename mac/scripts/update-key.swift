// Cookie's update signing key (Ed25519, CryptoKit). Run with `swift scripts/update-key.swift …`.
//
//   keygen <private-key-file>                     writes a new key (0600, refuses to overwrite), prints its public key
//   public <private-key-file>                     prints the public key (base64 of the 32 raw bytes)
//   sign <private-key-file> <version> <build> <sha256>    prints the signature (base64) over the update message
//   verify <public-key-base64> <version> <build> <sha256> <signature-base64>   exits 0 only for a good signature
//
// The message is the one CookieUpdater.swift checks (CookieUpdateVerifier.signedMessage): it binds the
// archive's SHA-256 to its version and build, so an old archive can't be relabelled as a new release.
// The private key file holds the 32 raw key bytes, base64, and never leaves ~/.cookie-release.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-key: \(message)\n".utf8))
    exit(1)
}

func signedMessage(version: String, build: String, sha256: String) -> Data {
    Data("cookie-update:v1\n\(version)\n\(build)\n\(sha256.lowercased())\n".utf8)
}

func loadPrivateKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    let url = URL(fileURLWithPath: path)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let mode = attributes[.posixPermissions] as? Int else { fail("no key at \(path)") }
    guard mode & 0o077 == 0 else { fail("\(path) is readable by others (mode \(String(mode, radix: 8))); chmod 600 it") }
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { fail("\(path) is not an Ed25519 key") }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "keygen" where arguments.count == 2:
    let path = arguments[1]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) already exists; a new key would orphan every installed Cookie") }
    let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("couldn't write \(path)") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public" where arguments.count == 2:
    print(loadPrivateKey(arguments[1]).publicKey.rawRepresentation.base64EncodedString())
case "sign" where arguments.count == 5:
    let key = loadPrivateKey(arguments[1])
    guard let signature = try? key.signature(for: signedMessage(version: arguments[2], build: arguments[3], sha256: arguments[4])) else { fail("signing failed") }
    print(signature.base64EncodedString())
case "verify" where arguments.count == 6:
    guard let raw = Data(base64Encoded: arguments[1]), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
          let signature = Data(base64Encoded: arguments[5]) else { fail("bad public key or signature") }
    guard publicKey.isValidSignature(signature, for: signedMessage(version: arguments[2], build: arguments[3], sha256: arguments[4])) else {
        fail("the signature does not match")
    }
    print("signature ok")
default:
    fail("usage: keygen <key> | public <key> | sign <key> <version> <build> <sha256> | verify <public> <version> <build> <sha256> <signature>")
}
