import Foundation
import Security

/// Generic-password entries are isolated by app service and opaque source UUID; no credentials in JSON/logs.
public struct SMBCredentialStore: Sendable {
    public enum Failure: Error { case unavailable; case status(OSStatus) }
    public let service: String
    public init(service: String) { self.service=service }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
         kSecAttrAccount as String:id.uuidString,kSecAttrSynchronizable as String:false]
    }
    public func save(_ password: String, for id: UUID) throws {
        var attributes: [String:Any] = [kSecValueData as String:Data(password.utf8),
            kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result=SecItemUpdate(query(id) as CFDictionary,attributes as CFDictionary)
        if result == errSecItemNotFound {
            attributes.merge(query(id)) { current,_ in current }
            let added=SecItemAdd(attributes as CFDictionary,nil)
            guard added==errSecSuccess else { throw Failure.status(added) }
        } else if result != errSecSuccess { throw Failure.status(result) }
    }
    public func load(for id: UUID) throws -> String? {
        var q=query(id);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result: CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status==errSecSuccess, let data=result as? Data, let value=String(data:data,encoding:.utf8) else { throw Failure.unavailable }
        return value
    }
    public func remove(for id: UUID) throws {
        let status=SecItemDelete(query(id) as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else { throw Failure.unavailable }
    }
}
