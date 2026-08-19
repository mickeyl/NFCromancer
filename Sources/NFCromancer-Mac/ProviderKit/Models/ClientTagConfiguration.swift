import Foundation

/// A tag fixture uploaded by a connected simulator app (typically a UI test).
/// Wire-shaped: string ids the test chooses, so it can `presentTag` them by
/// name. Ephemeral — never written to the user's library, cleared on
/// disconnect.
public struct ClientTagConfiguration: Codable, Equatable {
    public var name: String?
    public var tags: [ClientTag]
}

public struct ClientTag: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String?
    public var kind: MockTag.Kind
    public var value: String
    public var uid: String?

    /// The internal mock tag this fixture presents (fresh UUID; the wire id is
    /// the presentation key, kept in the server's dictionary).
    var asMockTag: MockTag {
        MockTag(name: name ?? id, kind: kind, value: value, uid: uid ?? "")
    }
}
