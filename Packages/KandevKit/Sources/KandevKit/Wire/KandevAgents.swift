import Foundation

/// An agent runtime, as `GET /api/v1/agents` reports it.
///
/// Verified against a live v0.96.0 server. Each runtime carries its own profiles,
/// so the list has to be flattened before it can be offered as a choice.
public struct KandevAgentRuntime: Sendable, Decodable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Whether this runtime can be the author of a conversation. The `dynamic`
    /// runtime cannot: it is a routing placeholder with no profiles.
    public var inferenceCapable: Bool?
    public var supportsMCP: Bool?
    public var capabilityStatus: String?
    public var profiles: [KandevAgentProfile]

    public enum CodingKeys: String, CodingKey {
        case id, name, profiles
        case inferenceCapable = "inference_capable"
        case supportsMCP = "supports_mcp"
        case capabilityStatus = "capability_status"
    }
}

/// One configured agent profile: which runtime, which model, and how it behaves.
public struct KandevAgentProfile: Sendable, Decodable, Equatable, Identifiable {
    public var id: String
    public var agentID: String?
    public var name: String
    /// What the runtime calls itself, for when the profile name is unhelpful.
    public var agentDisplayName: String?
    public var model: String?
    /// `concrete` or a routing kind.
    public var kind: String?
    public var enabled: Bool?
    public var autoApprove: Bool?
    public var billingType: String?
    /// Whether the runtime claims this model is actually available. False means
    /// the profile exists but the model behind it does not, so offering it would
    /// promise something the server cannot deliver.
    public var providerSupported: Bool?

    public enum CodingKeys: String, CodingKey {
        case id, name, model, kind, enabled
        case agentID = "agent_id"
        case agentDisplayName = "agent_display_name"
        case autoApprove = "auto_approve"
        case billingType = "billing_type"
        case providerSupported = "provider_supported"
    }

    public init(
        id: String,
        agentID: String? = nil,
        name: String = "",
        agentDisplayName: String? = nil,
        model: String? = nil,
        kind: String? = nil,
        enabled: Bool? = nil,
        autoApprove: Bool? = nil,
        billingType: String? = nil,
        providerSupported: Bool? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.name = name
        self.agentDisplayName = agentDisplayName
        self.model = model
        self.kind = kind
        self.enabled = enabled
        self.autoApprove = autoApprove
        self.billingType = billingType
        self.providerSupported = providerSupported
    }

    /// Whether this profile is worth offering as a choice.
    ///
    /// A profile can be present, disabled, or backed by a model the runtime does
    /// not have. Starting a session with one of those fails on the server, so it
    /// is not shown rather than shown and then refused.
    public var isSelectable: Bool {
        guard enabled == true, !id.isEmpty else { return false }
        return providerSupported != false
    }

    /// A label that distinguishes two profiles of the same runtime.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let model, !model.isEmpty { return model }
        return String(id.prefix(8))
    }
}

/// The answer to `GET /api/v1/agents`.
public struct KandevAgentCatalogue: Sendable, Decodable, Equatable {
    public var agents: [KandevAgentRuntime]
    public var total: Int?

    /// Every selectable profile, runtime name attached.
    ///
    /// Flattened here rather than by each caller: which profile to run is one
    /// choice, and it should not require knowing that the server groups them.
    public var selectableProfiles: [KandevAgentProfile] {
        agents
            .filter { $0.inferenceCapable != false }
            .flatMap { runtime in
                runtime.profiles
                    .filter(\.isSelectable)
                    .map { profile in
                        var copy = profile
                        if copy.agentDisplayName == nil { copy.agentDisplayName = runtime.name }
                        return copy
                    }
            }
    }
}
