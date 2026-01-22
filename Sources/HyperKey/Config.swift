import Cocoa

struct Config: Codable {
    var gap: Int = 10
    var useBuiltInHyper: Bool = false  // true = Caps Lock as Hyper, false = needs Karabiner
    var bindings: [Binding] = []

    struct Binding: Codable {
        let id: String
        let key: String
        let modifiers: [String]
        let action: Action

        // PERFORMANCE: Pre-computed values (not computed properties)
        let keyCode: UInt16
        let modifierFlags: NSEvent.ModifierFlags

        init(id: String, key: String, modifiers: [String], action: Action) {
            self.id = id
            self.key = key
            self.modifiers = modifiers
            self.action = action
            // Pre-compute once at init
            self.keyCode = KeyCodes.code(for: key) ?? 0
            self.modifierFlags = Self.computeModifierFlags(modifiers)
        }

        private static func computeModifierFlags(_ modifiers: [String]) -> NSEvent.ModifierFlags {
            var flags: NSEvent.ModifierFlags = []
            for mod in modifiers {
                switch mod.lowercased() {
                case "cmd", "command": flags.insert(.command)
                case "alt", "option": flags.insert(.option)
                case "ctrl", "control": flags.insert(.control)
                case "shift": flags.insert(.shift)
                default: break
                }
            }
            return flags
        }

        // Custom Codable to handle pre-computed fields
        enum CodingKeys: String, CodingKey {
            case id, key, modifiers, action
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            key = try container.decode(String.self, forKey: .key)
            modifiers = try container.decode([String].self, forKey: .modifiers)
            action = try container.decode(Action.self, forKey: .action)
            // Pre-compute
            keyCode = KeyCodes.code(for: key) ?? 0
            modifierFlags = Self.computeModifierFlags(modifiers)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(key, forKey: .key)
            try container.encode(modifiers, forKey: .modifiers)
            try container.encode(action, forKey: .action)
        }
    }

    enum Action: Codable {
        case toggleApp(bundleId: String)
        case toggleBraveProfile(profile: String)
        case toggleSafariProfile(profile: String)
        case cycleWindows
        case moveToNextScreen
        case toggleLayoutMode
        case focusDisplay(index: Int)
        case toggleFloat

        enum CodingKeys: String, CodingKey {
            case type
            case bundleId
            case profile
            case index
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .toggleApp(let bundleId):
                try container.encode("toggleApp", forKey: .type)
                try container.encode(bundleId, forKey: .bundleId)
            case .toggleBraveProfile(let profile):
                try container.encode("toggleBraveProfile", forKey: .type)
                try container.encode(profile, forKey: .profile)
            case .toggleSafariProfile(let profile):
                try container.encode("toggleSafariProfile", forKey: .type)
                try container.encode(profile, forKey: .profile)
            case .cycleWindows:
                try container.encode("cycleWindows", forKey: .type)
            case .moveToNextScreen:
                try container.encode("moveToNextScreen", forKey: .type)
            case .toggleLayoutMode:
                try container.encode("toggleLayoutMode", forKey: .type)
            case .focusDisplay(let index):
                try container.encode("focusDisplay", forKey: .type)
                try container.encode(index, forKey: .index)
            case .toggleFloat:
                try container.encode("toggleFloat", forKey: .type)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "toggleApp":
                let bundleId = try container.decode(String.self, forKey: .bundleId)
                self = .toggleApp(bundleId: bundleId)
            case "toggleBraveProfile":
                let profile = try container.decode(String.self, forKey: .profile)
                self = .toggleBraveProfile(profile: profile)
            case "toggleSafariProfile":
                let profile = try container.decode(String.self, forKey: .profile)
                self = .toggleSafariProfile(profile: profile)
            case "cycleWindows":
                self = .cycleWindows
            case "moveToNextScreen":
                self = .moveToNextScreen
            case "toggleLayoutMode":
                self = .toggleLayoutMode
            case "focusDisplay":
                let index = try container.decode(Int.self, forKey: .index)
                self = .focusDisplay(index: index)
            case "toggleFloat":
                self = .toggleFloat
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown action type")
            }
        }
    }

    static let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/bless/hyperwm/config.json")

    static func load() -> Config {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            print("No config found at \(configPath.path), creating default")
            let defaultConfig = createDefault()
            defaultConfig.save()
            return defaultConfig
        }

        do {
            let data = try Data(contentsOf: configPath)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            print("⚠️  Config parse error: \(error.localizedDescription)")
            print("⚠️  Using default config. Fix \(configPath.path) to restore your settings.")
            return createDefault()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Config.configPath)
        }
    }

    static func createDefault() -> Config {
        let hyper: [String] = ["cmd", "alt", "ctrl", "shift"]

        return Config(
            gap: 10,
            bindings: [
                // Apps (matching your AeroSpace config)
                Binding(id: "toggle-ghostty", key: "e", modifiers: hyper,
                       action: .toggleApp(bundleId: "com.mitchellh.ghostty")),
                Binding(id: "toggle-slack", key: "r", modifiers: hyper,
                       action: .toggleApp(bundleId: "com.tinyspeck.slackmacgap")),
                Binding(id: "toggle-calendar", key: "a", modifiers: hyper,
                       action: .toggleApp(bundleId: "com.apple.iCal")),
                Binding(id: "toggle-reminders", key: "s", modifiers: hyper,
                       action: .toggleApp(bundleId: "com.apple.reminders")),
                Binding(id: "toggle-notes", key: "d", modifiers: hyper,
                       action: .toggleApp(bundleId: "com.apple.Notes")),
                Binding(id: "toggle-finder", key: "f", modifiers: hyper,
                       action: .toggleApp(bundleId: "com.apple.finder")),

                // Safari profiles
                Binding(id: "toggle-safari-personal", key: "q", modifiers: hyper,
                       action: .toggleSafariProfile(profile: "P")),
                Binding(id: "toggle-safari-work", key: "w", modifiers: hyper,
                       action: .toggleSafariProfile(profile: "B")),

                // Window management
                Binding(id: "next-screen", key: "space", modifiers: hyper,
                       action: .moveToNextScreen),
                Binding(id: "cycle", key: "tab", modifiers: hyper,
                       action: .cycleWindows),
                Binding(id: "toggle-float", key: "`", modifiers: hyper,
                       action: .toggleFloat),

                // Focus displays (press again to toggle layout)
                Binding(id: "focus-display-1", key: "1", modifiers: hyper,
                       action: .focusDisplay(index: 0)),
                Binding(id: "focus-display-2", key: "2", modifiers: hyper,
                       action: .focusDisplay(index: 1)),
            ]
        )
    }
}

// MARK: - Key Codes

enum KeyCodes {
    static let mapping: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
        "space": 49, "return": 36, "tab": 48, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static func code(for key: String) -> UInt16? {
        mapping[key.lowercased()]
    }
}
