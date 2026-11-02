// Core value types: what a feature asks for, and where the device is.
//
// The load-bearing rule of this package is that features ask for a *capability*
// ("summarize this"), never for a model or a provider. Everything that decides
// *who* answers lives behind the plane.

/// A unit of AI work a feature can request. Features never name a model.
public enum Capability: String, Sendable, CaseIterable, Codable, Hashable {
    case summarize
    case translate
    case extract
    case rewrite
    case assistant
}

/// How sensitive the request payload is. Residency rules are keyed on this.
public enum DataClass: Int, Sendable, CaseIterable, Codable, Hashable, Comparable {
    case publicContent = 0
    case personal = 1
    case sensitive = 2

    public static func < (lhs: DataClass, rhs: DataClass) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A feature's request to the plane.
public struct CapabilityRequest: Sendable, Hashable {
    public let featureID: String
    public let capability: Capability
    public let dataClass: DataClass
    public let input: String

    public init(featureID: String, capability: Capability, dataClass: DataClass, input: String) {
        self.featureID = featureID
        self.capability = capability
        self.dataClass = dataClass
        self.input = input
    }
}

/// An ISO 3166-1 alpha-2 code, validated at construction (parse, don't validate later).
public struct CountryCode: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    /// Returns nil unless `code` is exactly two ASCII letters. Normalised to upper case.
    public init?(_ code: String) {
        let scalars = Array(code.unicodeScalars)
        guard scalars.count == 2,
              scalars.allSatisfy({ ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) })
        else { return nil }
        self.rawValue = code.uppercased()
    }

    public var description: String { rawValue }
    public static func < (lhs: CountryCode, rhs: CountryCode) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A semantic OS version. Negative components are clamped to zero so ordering is total.
public struct OSVersion: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
    }

    /// Parses "27", "27.3" or "27.3.1". `Int(_:)` returns nil on overflow, so this never traps.
    public init?(string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            values.append(value)
        }
        let minor = values.count > 1 ? values[1] : 0
        let patch = values.count > 2 ? values[2] : 0
        guard let major = values.first else { return nil }
        self.init(major, minor, patch)
    }

    public var description: String { "\(major).\(minor)" + (patch > 0 ? ".\(patch)" : "") }

    public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A regulatory zone that owns residency and availability rules.
public struct Jurisdiction: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let china = Jurisdiction("CN")
    public static let europeanUnion = Jurisdiction("EU")
    public static let unitedStates = Jurisdiction("US")
    public static let restOfWorld = Jurisdiction("ROW")

    public var description: String { rawValue }
    public static func < (lhs: Jurisdiction, rhs: Jurisdiction) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where the device is, legally and physically. Storefront and device region are
/// tracked separately because they disagree in practice (travel, gifted devices,
/// account region ≠ hardware region) and both carry rules.
public struct RegionContext: Hashable, Sendable {
    public var storefront: CountryCode
    public var deviceRegion: CountryCode
    public var osVersion: OSVersion
    public var isOnline: Bool

    public init(storefront: CountryCode, deviceRegion: CountryCode, osVersion: OSVersion, isOnline: Bool = true) {
        self.storefront = storefront
        self.deviceRegion = deviceRegion
        self.osVersion = osVersion
        self.isOnline = isOnline
    }
}

/// Maps countries to jurisdictions. Unknown countries fall into `fallback`.
public struct JurisdictionMap: Sendable {
    public let mapping: [CountryCode: Jurisdiction]
    public let fallback: Jurisdiction

    public init(mapping: [CountryCode: Jurisdiction], fallback: Jurisdiction = .restOfWorld) {
        self.mapping = mapping
        self.fallback = fallback
    }

    public func jurisdiction(for country: CountryCode) -> Jurisdiction {
        mapping[country] ?? fallback
    }

    /// Every jurisdiction whose rules bind this context. When storefront and device
    /// region disagree, *both* bind, and a provider must satisfy each of them
    /// ("strictest wins"). Sorted for deterministic output.
    public func bindingJurisdictions(for context: RegionContext) -> [Jurisdiction] {
        Array(Set([jurisdiction(for: context.storefront), jurisdiction(for: context.deviceRegion)])).sorted()
    }
}
