import Foundation

public enum OpDecodingError: Error, Hashable, Sendable {
    /// Written by a newer build; the app must update before it can apply this op.
    case unsupportedVersion(Int)
    case unknownKind(String)
}

/// Encodes ops as JSON bodies.
///
/// A body is encoded exactly once, by the device that authors the op. From then on the bytes are
/// stored, sent and hashed as they are and never re-encoded, so this format needs no byte-level
/// canonical form: an older build that drops fields it doesn't know still hashes the original
/// bytes.
public enum OpCodec {
    public static func encode(_ op: Op) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(Envelope(op))
    }

    public static func decode(_ body: Data) throws -> Op {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Envelope.self, from: body).op
    }
}

private struct Envelope: Codable {
    let op: Op

    init(_ op: Op) {
        self.op = op
    }

    private enum CodingKeys: String, CodingKey {
        case v, id, device, at, kind, payload
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .v)
        guard version <= Op.currentVersion else { throw OpDecodingError.unsupportedVersion(version) }
        let kindText = try c.decode(String.self, forKey: .kind)
        guard let kind = OpKind(rawValue: kindText) else { throw OpDecodingError.unknownKind(kindText) }

        func payload<T: Decodable>(_ type: T.Type) throws -> T {
            try c.decode(T.self, forKey: .payload)
        }
        let decoded: OpPayload = switch kind {
        case .createCommodity: .createCommodity(try payload(CreateCommodity.self))
        case .updateCommodity: .updateCommodity(try payload(UpdateCommodity.self))
        case .archiveCommodity: .archiveCommodity(try payload(Revise<Commodity>.self))
        case .openAccount: .openAccount(try payload(OpenAccount.self))
        case .updateAccount: .updateAccount(try payload(UpdateAccount.self))
        case .closeAccount: .closeAccount(try payload(CloseAccount.self))
        case .reopenAccount: .reopenAccount(try payload(Revise<Account>.self))
        case .archiveAccount: .archiveAccount(try payload(Revise<Account>.self))
        case .mergeAccounts: .mergeAccounts(try payload(MergeAccounts.self))
        case .deleteAccount: .deleteAccount(try payload(Revise<Account>.self))
        case .postEntry: .postEntry(try payload(PostEntry.self))
        case .amendEntry: .amendEntry(try payload(AmendEntry.self))
        case .voidEntry: .voidEntry(try payload(Revise<Entry>.self))
        case .setPrice: .setPrice(try payload(SetPrice.self))
        case .removePrice: .removePrice(try payload(Revise<Price>.self))
        case .assertBalance: .assertBalance(try payload(AssertBalance.self))
        case .removeAssertion: .removeAssertion(try payload(Revise<BalanceAssertion>.self))
        case .setSetting: .setSetting(try payload(SetSetting.self))
        case .dismissConflict: .dismissConflict(try payload(DismissConflict.self))
        }

        op = Op(
            version: version,
            id: try c.decode(Op.ID.self, forKey: .id),
            device: try c.decode(DeviceID.self, forKey: .device),
            at: try c.decode(HLCTimestamp.self, forKey: .at),
            payload: decoded
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(op.version, forKey: .v)
        try c.encode(op.id, forKey: .id)
        try c.encode(op.device, forKey: .device)
        try c.encode(op.at, forKey: .at)
        try c.encode(op.kind.rawValue, forKey: .kind)
        switch op.payload {
        case .createCommodity(let p): try c.encode(p, forKey: .payload)
        case .updateCommodity(let p): try c.encode(p, forKey: .payload)
        case .archiveCommodity(let p): try c.encode(p, forKey: .payload)
        case .openAccount(let p): try c.encode(p, forKey: .payload)
        case .updateAccount(let p): try c.encode(p, forKey: .payload)
        case .closeAccount(let p): try c.encode(p, forKey: .payload)
        case .reopenAccount(let p): try c.encode(p, forKey: .payload)
        case .archiveAccount(let p): try c.encode(p, forKey: .payload)
        case .mergeAccounts(let p): try c.encode(p, forKey: .payload)
        case .deleteAccount(let p): try c.encode(p, forKey: .payload)
        case .postEntry(let p): try c.encode(p, forKey: .payload)
        case .amendEntry(let p): try c.encode(p, forKey: .payload)
        case .voidEntry(let p): try c.encode(p, forKey: .payload)
        case .setPrice(let p): try c.encode(p, forKey: .payload)
        case .removePrice(let p): try c.encode(p, forKey: .payload)
        case .assertBalance(let p): try c.encode(p, forKey: .payload)
        case .removeAssertion(let p): try c.encode(p, forKey: .payload)
        case .setSetting(let p): try c.encode(p, forKey: .payload)
        case .dismissConflict(let p): try c.encode(p, forKey: .payload)
        }
    }
}
