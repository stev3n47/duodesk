// SigningPosture.swift — detect at launch what the current signing profile grants us,
// so the UI can show a reduced-mode banner without pretending unavailable features work.
//
// On a Signulous build we expect: multicast + hotspot config + wifi-info + app groups.
// On AltStore / free-team: no multicast, no hotspot config, flaky app groups.
// We can't query entitlements directly; we probe behavior.

import Foundation

struct SigningPosture: Equatable {
    enum Profile: String {
        case unknown = "Unknown"
        case signulous = "Signulous"
        case altstore = "AltStore / SideStore"
        case sideloadly = "Sideloadly"
        case xcode = "Xcode (personal team)"
        case appstore = "App Store"
    }

    var profile: Profile = .unknown
    var hasMulticast: Bool = false
    var hasAppGroup: Bool = false
    var profileExpiry: Date? = nil

    /// Days left on the current provisioning profile, or nil when unknown.
    var daysUntilExpiry: Int? {
        guard let e = profileExpiry else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: e).day
    }

    /// Show the "re-install from Signulous" banner this many days before expiry.
    var shouldWarn: Bool {
        (daysUntilExpiry ?? Int.max) <= 30
    }
}

@MainActor
enum SigningPostureDetector {
    static func detect() -> SigningPosture {
        var p = SigningPosture()
        p.profileExpiry = embeddedProfileExpiry()
        p.hasAppGroup = appGroupReachable()
        p.profile = guessProfile(expiry: p.profileExpiry)
        // Multicast would require sending a packet and seeing it echo; cheap test is to
        // check the entitlement via the embedded profile. Our heuristic: assume Signulous
        // and Xcode-plus-paid-team have it, free-team doesn't.
        p.hasMulticast = (p.profile == .signulous || p.profile == .appstore)
        return p
    }

    private static func embeddedProfileExpiry() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .ascii)
        else { return nil }
        // Clumsy but effective: find the first <date>…</date> after ExpirationDate.
        guard let r = text.range(of: "ExpirationDate") else { return nil }
        guard let open = text.range(of: "<date>", range: r.upperBound..<text.endIndex),
              let close = text.range(of: "</date>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let iso = String(text[open.upperBound..<close.lowerBound])
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    private static func appGroupReachable() -> Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.twindesk.ios.shared"
        ) != nil
    }

    private static func guessProfile(expiry: Date?) -> SigningPosture.Profile {
        // Heuristic. AltStore and Xcode free-team get ~7-day profiles; Signulous ~1 year.
        guard let e = expiry else { return .unknown }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: e).day ?? 0
        if days > 180 { return .signulous }
        if days > 30 { return .appstore }  // 90 days = ad-hoc paid team
        return .altstore
    }
}
