import CryptoKit
import Foundation

@MainActor
enum CookieRelayTests {
    static func run() {
        let relay = CookieRelay.shared
        relay.dismissOutgoing()
        relay.dismissIncoming()
        relay.dismissBoardDraft()
        relay.onPresent = nil
        var checks = 0

        let messages = [CompanionChatMessage(role: .user, text: "Export the Q3 report"),
                        CompanionChatMessage(role: .assistant, text: "The Board item is ready for review.")]
        var work = WorkItem(title: "Q3 report", outcome: "Ready for teammate review", nextStep: "Confirm the final totals")
        work.history = [WorkEvent(text: "Prepared the report", by: "cookie")]
        work.memoryID = "01J00000000000000000000000"
        precondition(CookieRelayVoiceCommand.recipient(in: "Hand this to Priya") == "Priya")
        precondition(CookieRelayVoiceCommand.recipient(in: "Could you hand this to Priya") == nil)
        let handled = relay.handleVoiceRequest("hand this to Priya", source: .init(messages: messages, selectedText: "Q3 only", work: work), from: "Naveen")
        precondition(handled && relay.outgoingPacket?.to == "Priya")
        precondition(relay.outgoingPacket?.title == "Q3 report" && relay.outgoingPacket?.next.first?.text == "Confirm the final totals")
        precondition(relay.outgoingPacket?.memoryRefs == [work.memoryID!])
        relay.dismissOutgoing()
        checks += 1

        let previousProof = relay.proof
        let redactionProof = CookieProof(file: nil)
        relay.proof = redactionProof
        let secretSelectedText = "Use ghp_abcdefghijklmnopqrstuvwxyz0123456789AB for the report"
        precondition(relay.handleVoiceRequest("hand this to Priya",
            source: .init(messages: messages, selectedText: secretSelectedText, work: nil), from: "Naveen"))
        precondition(relay.outgoingPacket?.brief.contains("ghp_abcdefghijklmnopqrstuvwxyz") == false)
        precondition(redactionProof.today.contains { $0.kind == .redacted && $0.feature == "team-relay" })
        relay.dismissOutgoing()
        relay.proof = previousProof
        checks += 1

        relay.beginBoardHandoff(work, messages: messages)
        precondition(relay.boardDraft?.work.id == work.id)
        precondition(relay.prepareBoardHandoff(to: "Mira") && relay.outgoingPacket?.to == "Mira")
        precondition(relay.boardDraft == nil, "the Board action opens the same review-before-sharing flow")
        relay.dismissOutgoing()
        checks += 1

        let key = SymmetricKey(data: Data(repeating: 0x2a, count: 32))
        let signingKey = Curve25519.Signing.PrivateKey()
        let packet = CookieRelayPacket(version: 1, from: "Naveen", to: "Priya", title: "Q3 report",
            brief: "Review this token ghp_abcdefghijklmnopqrstuvwxyz0123456789AB and the totals.",
            done: ["Prepared the report"], next: [CookieRelayNextStep(value: .text("Confirm the totals"))],
            memoryRefs: [], createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let signed = try! CookieRelayCodec.encode(packet, key: key, signingKey: signingKey)
        guard case .verified(let verified) = try! CookieRelayCodec.inspect(signed, key: key) else {
            preconditionFailure("same-install HMAC verifies")
        }
        precondition(verified.brief.contains("•••") && !verified.brief.contains("ghp_abcdefghijklmnopqrstuvwxyz"))
        checks += 1

        var envelope = try! JSONSerialization.jsonObject(with: signed) as! [String: Any]
        var payload = Data(base64Encoded: envelope["payload"] as! String)!
        payload[0] ^= 1
        envelope["payload"] = payload.base64EncodedString()
        let tampered = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        do {
            _ = try CookieRelayCodec.inspect(tampered, key: key)
            preconditionFailure("tampered content must be rejected")
        } catch CookieRelayCodecError.tampered {
            checks += 1
        } catch {
            preconditionFailure("unexpected tamper failure: \(error)")
        }

        let otherKey = SymmetricKey(data: Data(repeating: 0x7b, count: 32))
        guard case .foreignInstallation(let unverified) = try! CookieRelayCodec.inspect(signed, key: otherKey) else {
            preconditionFailure("a foreign per-install key must be reported as unverified")
        }
        precondition(unverified.title == "Q3 report")
        checks += 1

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("cookierelay")
        try! signed.write(to: file, options: .atomic)
        let oldProvider = relay.keyProvider
        relay.keyProvider = { otherKey }
        relay.openFile(file)
        let deadline = Date().addingTimeInterval(2)
        while relay.incoming == .loading && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard case .unverified(let opened, let warning) = relay.incoming else { preconditionFailure("opening a teammate .cookierelay routes to its explicitly unpaired preview") }
        precondition(opened == verified)
        precondition(warning.contains("isn't paired") && warning.contains("isn't identity-verified"))
        checks += 1
        let pickUpStore = WorkStore(connected: false)
        let navigation = CookieNavigation()
        let pickedThreadID = UUID()
        var seededChat = ""
        let previousProofForPickUp = relay.proof
        let pickUpProof = CookieProof(file: nil)
        relay.proof = pickUpProof
        relay.pickUp(opened, navigation: navigation, workStore: pickUpStore) { _, seed in
            seededChat = seed
            return pickedThreadID
        }
        guard case .pickedUp(let workID, let threadID) = relay.incoming,
              let pickedWork = pickUpStore.item(workID) else {
            preconditionFailure("Pick it up creates a local Board item and seeded chat")
        }
        precondition(threadID == pickedThreadID && pickedWork.threadID == pickedThreadID)
        precondition(pickedWork.title == opened.title && pickedWork.nextStep == opened.next.first?.text)
        precondition(seededChat.contains(opened.brief) && seededChat.contains("normal start_task plan"))
        precondition(pickUpProof.today.contains { $0.kind == .acted && $0.feature == "team-relay" })
        precondition(navigation.section == .board && navigation.openWork == workID)
        relay.proof = previousProofForPickUp
        relay.dismissIncoming()
        relay.keyProvider = oldProvider
        try? FileManager.default.removeItem(at: file)
        checks += 1

        let plistURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Cookie/Info.plist")
        let plist = try! PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as! [String: Any]
        let documentTypes = plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let exports = plist["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        precondition(documentTypes.contains { ($0["LSItemContentTypes"] as? [String])?.contains("com.enkeon.cookie.relay") == true })
        precondition(exports.contains {
            ($0["UTTypeIdentifier"] as? String) == "com.enkeon.cookie.relay" &&
            (((($0["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String]) ?? []).contains("cookierelay"))
        })
        checks += 1

        print("\(checks) team relay checks passed.")
    }
}
