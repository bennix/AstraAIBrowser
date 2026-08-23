// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation
import LocalAuthentication
import Security

struct WebCredentialDescriptor: Equatable {
    let account: String
    let origin: String
    let username: String
    let modifiedAt: Date
}

enum WebCredentialStoreError: LocalizedError {
    case invalidInput
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return NSLocalizedString(
                "passwords.webCredential.error.invalidInput",
                value: "This login cannot be saved securely.",
                comment: "Web password manager - Error shown when a submitted login has invalid or incomplete fields"
            )
        case .keychain(let status):
            return String(
                format: NSLocalizedString(
                    "passwords.webCredential.error.keychain",
                    value: "macOS Keychain could not complete the request (%ld).",
                    comment: "Web password manager - Error containing the macOS Keychain status code"
                ),
                status
            )
        }
    }
}

final class WebCredentialStore {
    static let shared = WebCredentialStore()

    private let service: String

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.phibrowser.Mac") {
        service = "\(bundleIdentifier).web-credentials"
    }

    static func secureOrigin(from rawValue: String) -> String? {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        var origin = "https://\(host)"
        if let port = components.port, port != 443 {
            origin += ":\(port)"
        }
        return origin
    }

    func descriptors(for origin: String) -> [WebCredentialDescriptor] {
        guard let origin = Self.secureOrigin(from: origin) else { return [] }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        query.removeAll(keepingCapacity: false)
        return items.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  let storedOrigin = attributes[kSecAttrComment as String] as? String,
                  storedOrigin == origin,
                  let username = attributes[kSecAttrLabel as String] as? String else {
                return nil
            }
            return WebCredentialDescriptor(
                account: account,
                origin: storedOrigin,
                username: username,
                modifiedAt: attributes[kSecAttrModificationDate as String] as? Date ?? .distantPast
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func save(origin rawOrigin: String, username rawUsername: String, password: String) throws {
        guard let origin = Self.secureOrigin(from: rawOrigin) else {
            throw WebCredentialStoreError.invalidInput
        }
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty,
              username.count <= 320,
              !password.isEmpty,
              password.utf8.count <= 4_096 else {
            throw WebCredentialStoreError.invalidInput
        }
        let account = Self.account(origin: origin, username: username)
        let data = Data(password.utf8)
        let existing = descriptors(for: origin).contains { $0.account == account }
        if existing {
            let context = LAContext()
            context.localizedReason = String(
                format: NSLocalizedString(
                    "passwords.webCredential.touchID.updateReason",
                    value: "Update the saved password for %@",
                    comment: "Web password manager - Touch ID reason for replacing an existing website password; placeholder is the username"
                ),
                username
            )
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecUseAuthenticationContext as String: context,
            ]
            let status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecSuccess else {
                throw WebCredentialStoreError.keychain(status)
            }
            return
        }

        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            throw WebCredentialStoreError.invalidInput
        }
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: username,
            kSecAttrComment as String: origin,
            kSecAttrAccessControl as String: accessControl,
            kSecValueData as String: data,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WebCredentialStoreError.keychain(status)
        }
    }

    func password(
        for descriptor: WebCredentialDescriptor,
        reason: String
    ) throws -> String {
        let context = LAContext()
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: descriptor.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            kSecUseOperationPrompt as String: reason,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw WebCredentialStoreError.keychain(status)
        }
        return password
    }

    private static func account(origin: String, username: String) -> String {
        let encodedOrigin = Data(origin.utf8).base64EncodedString()
        return "\(encodedOrigin)|\(username)"
    }
}
