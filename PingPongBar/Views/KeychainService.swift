import Foundation
import Security

public struct KeychainHelper {
    @discardableResult
    public static func savePassword(_ password: String, service: String, account: String) -> Bool {
        let passwordData = password.data(using: .utf8)!
        
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        
        let attributesToUpdate: [CFString: Any] = [
            kSecValueData: passwordData,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        // Try to update existing item
        let statusUpdate = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if statusUpdate == errSecSuccess {
            return true
        }
        
        if statusUpdate == errSecItemNotFound {
            // Add new item
            var newItem = query
            newItem[kSecValueData] = passwordData
            newItem[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            
            let statusAdd = SecItemAdd(newItem as CFDictionary, nil)
            return statusAdd == errSecSuccess
        }
        
        return false
    }
    
    public static func loadPassword(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let passwordData = result as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            return nil
        }
        
        return password
    }
    
    @discardableResult
    public static func deletePassword(service: String, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
