// KeyMap.swift — what the Remote page types, as KeyboardEvent.code names (the host takes
// /^[A-Za-z0-9]{1,32}$/, shared/phone-remote.js). US layout: the computer turns a code into a
// key press, so a letter is "KeyA" and a capital is Shift + "KeyA".

import UIKit

enum KeyMap {
    struct Stroke: Equatable {
        let code: String
        let shift: Bool
    }

    private static let plain: [Character: String] = [
        " ": "Space", "\n": "Enter", "\r": "Enter", "\t": "Tab",
        "-": "Minus", "=": "Equal", "[": "BracketLeft", "]": "BracketRight", "\\": "Backslash",
        ";": "Semicolon", "'": "Quote", ",": "Comma", ".": "Period", "/": "Slash", "`": "Backquote",
    ]

    private static let shifted: [Character: String] = [
        "!": "Digit1", "@": "Digit2", "#": "Digit3", "$": "Digit4", "%": "Digit5",
        "^": "Digit6", "&": "Digit7", "*": "Digit8", "(": "Digit9", ")": "Digit0",
        "_": "Minus", "+": "Equal", "{": "BracketLeft", "}": "BracketRight", "|": "Backslash",
        ":": "Semicolon", "\"": "Quote", "<": "Comma", ">": "Period", "?": "Slash", "~": "Backquote",
    ]

    /// The key press that types the character, or nil when no key does (accents, emoji...).
    static func stroke(for ch: Character) -> Stroke? {
        if ch.isNewline { return Stroke(code: "Enter", shift: false) }
        if let c = plain[ch] { return Stroke(code: c, shift: false) }
        if let c = shifted[ch] { return Stroke(code: c, shift: true) }
        guard ch.unicodeScalars.count == 1, let u = ch.unicodeScalars.first, u.isASCII else { return nil }
        switch u.value {
        case 0x61...0x7A: return Stroke(code: "Key" + String(ch).uppercased(), shift: false)
        case 0x41...0x5A: return Stroke(code: "Key" + String(ch), shift: true)
        case 0x30...0x39: return Stroke(code: "Digit" + String(ch), shift: false)
        default: return nil
        }
    }

    /// USB HID usage (UIKey.keyCode) -> KeyboardEvent.code, for a hardware keyboard.
    static func code(forHID usage: Int) -> String? {
        switch usage {
        case 0x04...0x1D: return "Key" + String(UnicodeScalar(UInt8(0x41 + usage - 0x04)))
        case 0x1E...0x26: return "Digit\(usage - 0x1E + 1)"
        case 0x27: return "Digit0"
        case 0x28: return "Enter"
        case 0x29: return "Escape"
        case 0x2A: return "Backspace"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x2D: return "Minus"
        case 0x2E: return "Equal"
        case 0x2F: return "BracketLeft"
        case 0x30: return "BracketRight"
        case 0x31: return "Backslash"
        case 0x33: return "Semicolon"
        case 0x34: return "Quote"
        case 0x35: return "Backquote"
        case 0x36: return "Comma"
        case 0x37: return "Period"
        case 0x38: return "Slash"
        case 0x39: return "CapsLock"
        case 0x3A...0x45: return "F\(usage - 0x3A + 1)"
        case 0x49: return "Insert"
        case 0x4A: return "Home"
        case 0x4B: return "PageUp"
        case 0x4C: return "Delete"
        case 0x4D: return "End"
        case 0x4E: return "PageDown"
        case 0x4F: return "ArrowRight"
        case 0x50: return "ArrowLeft"
        case 0x51: return "ArrowDown"
        case 0x52: return "ArrowUp"
        case 0xE0: return "ControlLeft"
        case 0xE1: return "ShiftLeft"
        case 0xE2: return "AltLeft"
        case 0xE3: return "MetaLeft"
        case 0xE4: return "ControlRight"
        case 0xE5: return "ShiftRight"
        case 0xE6: return "AltRight"
        case 0xE7: return "MetaRight"
        default: return nil
        }
    }
}
