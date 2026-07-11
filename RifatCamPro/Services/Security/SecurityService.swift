import Foundation
import CryptoKit
import Combine
import Observation

@Observable
final class SecurityService {

    // MARK: - Published State

    private(set) var isAuthenticated = false
    private(set) var activeTokens: [SessionToken] = []
    private(set) var lastError: SecurityError?

    // MARK: - Configuration

    private let saltLength = 32
    private let tokenLength = 64
    private let tokenValidityDuration: TimeInterval = 86_400
    private let maxActiveTokens = 10

    // MARK: - Keychain Keys

    private let passwordHashKey = "com.rifatcam.security.passwordHash"
    private let passwordSaltKey = "com.rifatcam.security.passwordSalt"

    // MARK: - Combine

    let authenticationStateChanged = PassthroughSubject<Bool, Never>()
    let errorSubject = PassthroughSubject<SecurityError, Never>()

    // MARK: - Storage

    private let defaults = UserDefaults.standard
    private let lock = NSLock()

    // MARK: - Initialization

    init() {
        cleanupExpiredTokens()
    }

    // MARK: - Password Hashing

    func hashPassword(_ password: String, salt: Data? = nil) -> PasswordHash {
        let saltData = salt ?? generateSalt()
        let passwordData = Data(password.utf8)
        var combined = Data()
        combined.append(saltData)
        combined.append(passwordData)

        let hashed = SHA256.hash(data: combined)
        let hashData = Data(hashed)

        return PasswordHash(
            hash: hashData.base64EncodedString(),
            salt: saltData.base64EncodedString(),
            algorithm: "SHA256"
        )
    }

    func generateSalt() -> Data {
        var salt = Data(count: saltLength)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, saltLength, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            return Data("RifatCamProStaticSalt".utf8)
        }
        return salt
    }

    func validatePassword(_ password: String, against storedHash: String, salt: String) -> Bool {
        guard let saltData = Data(base64Encoded: salt) else {
            return false
        }
        let result = hashPassword(password, salt: saltData)
        return result.hash == storedHash
    }

    // MARK: - Password Storage

    func storePassword(_ password: String) -> Bool {
        let hashResult = hashPassword(password)

        lock.lock()
        defer { lock.unlock() }

        defaults.set(hashResult.hash, forKey: passwordHashKey)
        defaults.set(hashResult.salt, forKey: passwordSaltKey)

        return true
    }

    func verifyStoredPassword(_ password: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let storedHash = defaults.string(forKey: passwordHashKey),
              let storedSalt = defaults.string(forKey: passwordSaltKey) else {
            return false
        }

        return validatePassword(password, against: storedHash, salt: storedSalt)
    }

    func hasStoredPassword() -> Bool {
        defaults.string(forKey: passwordHashKey) != nil
    }

    func clearStoredPassword() {
        lock.lock()
        defer { lock.unlock() }

        defaults.removeObject(forKey: passwordHashKey)
        defaults.removeObject(forKey: passwordSaltKey)
        isAuthenticated = false
        authenticationStateChanged.send(false)
    }

    // MARK: - Session Token Management

    func generateSessionToken(for clientID: String) -> SessionToken? {
        guard hasStoredPassword() else {
            return SessionToken(
                token: generateRandomToken(),
                clientID: clientID,
                expiry: Date().addingTimeInterval(tokenValidityDuration),
                createdAt: Date()
            )
        }

        lock.lock()
        defer { lock.unlock() }

        if activeTokens.count >= maxActiveTokens {
            cleanupExpiredTokens()
            if activeTokens.count >= maxActiveTokens {
                return nil
            }
        }

        let token = SessionToken(
            token: generateRandomToken(),
            clientID: clientID,
            expiry: Date().addingTimeInterval(tokenValidityDuration),
            createdAt: Date()
        )

        activeTokens.append(token)
        return token
    }

    func validateToken(_ tokenString: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        cleanupExpiredTokens()

        guard let token = activeTokens.first(where: { $0.token == tokenString }) else {
            return false
        }

        return token.expiry > Date()
    }

    func validateToken(_ tokenString: String, forClientID clientID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        cleanupExpiredTokens()

        guard let token = activeTokens.first(where: {
            $0.token == tokenString && $0.clientID == clientID
        }) else {
            return false
        }

        return token.expiry > Date()
    }

    func revokeToken(_ tokenString: String) {
        lock.lock()
        defer { lock.unlock() }

        activeTokens.removeAll { $0.token == tokenString }
    }

    func revokeAllTokens(for clientID: String) {
        lock.lock()
        defer { lock.unlock() }

        activeTokens.removeAll { $0.clientID == clientID }
    }

    func revokeAllTokens() {
        lock.lock()
        defer { lock.unlock() }

        activeTokens.removeAll()
        isAuthenticated = false
        authenticationStateChanged.send(false)
    }

    // MARK: - Connection Authentication

    func authenticateConnection(password: String) -> ConnectionAuthResult {
        if !hasStoredPassword() {
            isAuthenticated = true
            authenticationStateChanged.send(true)
            return .success(token: nil)
        }

        guard verifyStoredPassword(password) else {
            lastError = .invalidPassword
            errorSubject.send(.invalidPassword)
            return .failure(.invalidPassword)
        }

        isAuthenticated = true
        authenticationStateChanged.send(true)
        let token = generateSessionToken(for: UUID().uuidString)
        return .success(token: token?.token)
    }

    func authenticateConnection(token: String, clientID: String) -> ConnectionAuthResult {
        guard validateToken(token, forClientID: clientID) else {
            isAuthenticated = false
            authenticationStateChanged.send(false)
            lastError = .invalidToken
            errorSubject.send(.invalidToken)
            return .failure(.invalidToken)
        }

        isAuthenticated = true
        authenticationStateChanged.send(true)
        return .success(token: token)
    }

    func invalidateAuthentication() {
        isAuthenticated = false
        authenticationStateChanged.send(false)
    }

    // MARK: - Data Encryption (AES-GCM)

    func encryptData(_ data: Data, using key: SymmetricKey) throws -> EncryptedPayload {
        let sealedBox = try AES.GCM.seal(data, using: key)

        guard let combined = sealedBox.combined else {
            throw SecurityError.encryptionFailed("Failed to produce combined sealed box")
        }

        return EncryptedPayload(
            ciphertext: sealedBox.ciphertext,
            nonce: Data(sealedBox.nonce),
            tag: sealedBox.tag,
            combined: combined
        )
    }

    func decryptData(_ payload: EncryptedPayload, using key: SymmetricKey) throws -> Data {
        guard payload.tag.count == 16 else {
            throw SecurityError.decryptionFailed("Invalid authentication tag length")
        }

        let sealedBox = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: payload.nonce),
            ciphertext: payload.ciphertext,
            tag: payload.tag
        )

        return try AES.GCM.open(sealedBox, using: key)
    }

    func encryptData(_ data: Data, password: String) throws -> EncryptedPayload {
        let key = deriveKey(from: password)
        return try encryptData(data, using: key)
    }

    func decryptData(_ payload: EncryptedPayload, password: String) throws -> Data {
        let key = deriveKey(from: password)
        return try decryptData(payload, using: key)
    }

    func encryptData(_ data: Data, usingPassword password: String, salt: Data) throws -> EncryptedPayload {
        let key = deriveKey(from: password, salt: salt)
        return try encryptData(data, using: key)
    }

    func decryptData(_ payload: EncryptedPayload, usingPassword password: String, salt: Data) throws -> Data {
        let key = deriveKey(from: password, salt: salt)
        return try decryptData(payload, using: key)
    }

    // MARK: - Key Derivation

    func deriveKey(from password: String) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        let salt = Data("RifatCamPro.StaticSalt".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: passwordData),
            salt: salt,
            outputByteCount: 32
        )
        return derived
    }

    func deriveKey(from password: String, salt: Data) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: passwordData),
            salt: salt,
            outputByteCount: 32
        )
        return derived
    }

    func generateEncryptionKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // MARK: - QR Code Pairing Data

    func generatePairingData(port: UInt16, password: String?) -> PairingData {
        let deviceID = generateDeviceIdentifier()
        let token = generateRandomToken()

        var pairingDict: [String: Any] = [
            "protocol": "RifatCamPro",
            "version": 1,
            "port": Int(port),
            "deviceID": deviceID,
            "token": token,
            "timestamp": Date().timeIntervalSince1970
        ]

        if let password, !password.isEmpty {
            let salt = generateSalt()
            let hash = hashPassword(password, salt: salt)
            pairingDict["passwordHash"] = hash.hash
            pairingDict["passwordSalt"] = hash.salt
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: pairingDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return PairingData(
                raw: "",
                port: port,
                deviceID: deviceID,
                token: token,
                passwordHash: nil,
                passwordSalt: nil
            )
        }

        let passwordHash = pairingDict["passwordHash"] as? String
        let passwordSalt = pairingDict["passwordSalt"] as? String

        return PairingData(
            raw: jsonString,
            port: port,
            deviceID: deviceID,
            token: token,
            passwordHash: passwordHash,
            passwordSalt: passwordSalt
        )
    }

    func parsePairingData(from string: String) -> PairingData? {
        guard let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["protocol"] as? String == "RifatCamPro",
              let port = json["port"] as? Int,
              let deviceID = json["deviceID"] as? String,
              let token = json["token"] as? String else {
            return nil
        }

        return PairingData(
            raw: string,
            port: UInt16(port),
            deviceID: deviceID,
            token: token,
            passwordHash: json["passwordHash"] as? String,
            passwordSalt: json["passwordSalt"] as? String
        )
    }

    func validatePairingData(_ pairing: PairingData) -> Bool {
        guard !pairing.deviceID.isEmpty,
              !pairing.token.isEmpty,
              pairing.port > 0,
              pairing.port <= 65535 else {
            return false
        }

        let timeDiff = abs(Date().timeIntervalSince1970 - (try? JSONSerialization.jsonObject(
            with: pairing.raw.data(using: .utf8) ?? Data()
        ).flatMap { $0 as? [String: Any] }?["timestamp"] as? TimeInterval ?? 0))

        return timeDiff < 300
    }

    // MARK: - Incoming Connection Validation

    func validateIncomingConnection(
        address: String,
        port: UInt16,
        password: String?,
        storedPasswordHash: String?,
        storedPasswordSalt: String?
    ) -> ConnectionValidationResult {
        guard !address.isEmpty else {
            return .rejected(reason: "Empty address")
        }

        guard port > 0, port <= 65535 else {
            return .rejected(reason: "Invalid port")
        }

        if let password, let storedHash = storedPasswordHash, let storedSalt = storedPasswordSalt {
            guard validatePassword(password, against: storedHash, salt: storedSalt) else {
                return .rejected(reason: "Invalid password")
            }
        } else if storedPasswordHash != nil {
            return .requiresPassword
        }

        return .accepted
    }

    // MARK: - Security Warnings

    func checkSecurityConfiguration(networkConfig: NetworkConfiguration) -> [SecurityWarning] {
        var warnings: [SecurityWarning] = []

        if networkConfig.enablePasswordProtection && networkConfig.password.isEmpty {
            warnings.append(.passwordEnabledButEmpty)
        }

        if !networkConfig.enableTLS {
            warnings.append(.tlsDisabled)
        }

        if networkConfig.maxConnections > 5 {
            warnings.append(.highConnectionLimit)
        }

        if networkConfig.connectionTimeout > 60 {
            warnings.append(.longTimeout)
        }

        return warnings
    }

    // MARK: - Private Helpers

    private func generateRandomToken() -> String {
        var tokenData = Data(count: tokenLength)
        let status = tokenData.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, tokenLength, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return tokenData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateDeviceIdentifier() -> String {
        if let identifier = defaults.string(forKey: "com.rifatcam.deviceIdentifier") {
            return identifier
        }
        let identifier = UUID().uuidString
        defaults.set(identifier, forKey: "com.rifatcam.deviceIdentifier")
        return identifier
    }

    private func cleanupExpiredTokens() {
        let now = Date()
        activeTokens.removeAll { $0.expiry <= now }
    }
}

// MARK: - Types

struct PasswordHash: Sendable {
    let hash: String
    let salt: String
    let algorithm: String
}

struct SessionToken: Sendable, Identifiable {
    let id = UUID()
    let token: String
    let clientID: String
    let expiry: Date
    let createdAt: Date

    var isExpired: Bool {
        expiry <= Date()
    }

    var remainingTime: TimeInterval {
        max(0, expiry.timeIntervalSinceNow)
    }
}

struct EncryptedPayload: Sendable {
    let ciphertext: Data
    let nonce: Data
    let tag: Data
    let combined: Data
}

struct PairingData: Sendable {
    let raw: String
    let port: UInt16
    let deviceID: String
    let token: String
    let passwordHash: String?
    let passwordSalt: String?
}

enum ConnectionAuthResult: Sendable {
    case success(token: String?)
    case failure(SecurityError)
}

enum ConnectionValidationResult: Sendable {
    case accepted
    case requiresPassword
    case rejected(reason: String)
}

enum SecurityError: Error, Identifiable, Sendable {
    case invalidPassword
    case invalidToken
    case encryptionFailed(String)
    case decryptionFailed(String)
    case keyDerivationFailed
    case tokenExpired
    case maxTokensReached
    case invalidPairingData
    case securityMisconfiguration(String)

    var id: String {
        switch self {
        case .invalidPassword: return "invalid_password"
        case .invalidToken: return "invalid_token"
        case .encryptionFailed: return "encryption_failed"
        case .decryptionFailed: return "decryption_failed"
        case .keyDerivationFailed: return "key_derivation_failed"
        case .tokenExpired: return "token_expired"
        case .maxTokensReached: return "max_tokens"
        case .invalidPairingData: return "invalid_pairing"
        case .securityMisconfiguration: return "misconfiguration"
        }
    }

    var title: String {
        switch self {
        case .invalidPassword: return "Invalid Password"
        case .invalidToken: return "Invalid Token"
        case .encryptionFailed: return "Encryption Failed"
        case .decryptionFailed: return "Decryption Failed"
        case .keyDerivationFailed: return "Key Derivation Failed"
        case .tokenExpired: return "Token Expired"
        case .maxTokensReached: return "Max Connections Reached"
        case .invalidPairingData: return "Invalid Pairing Data"
        case .securityMisconfiguration: return "Security Warning"
        }
    }

    var message: String {
        switch self {
        case .invalidPassword: return "The provided password is incorrect."
        case .invalidToken: return "The authentication token is invalid or expired."
        case .encryptionFailed(let detail): return "Encryption failed: \(detail)"
        case .decryptionFailed(let detail): return "Decryption failed: \(detail)"
        case .keyDerivationFailed: return "Failed to derive encryption key."
        case .tokenExpired: return "The session token has expired."
        case .maxTokensReached: return "Maximum number of active connections reached."
        case .invalidPairingData: return "The QR pairing data is invalid or corrupted."
        case .securityMisconfiguration(let detail): return "Security configuration issue: \(detail)"
        }
    }
}

enum SecurityWarning: Sendable, Identifiable {
    case passwordEnabledButEmpty
    case tlsDisabled
    case highConnectionLimit
    case longTimeout

    var id: String {
        switch self {
        case .passwordEnabledButEmpty: return "password_empty"
        case .tlsDisabled: return "tls_disabled"
        case .highConnectionLimit: return "high_limit"
        case .longTimeout: return "long_timeout"
        }
    }

    var title: String {
        switch self {
        case .passwordEnabledButEmpty: return "Password Protection Active but Empty"
        case .tlsDisabled: return "TLS Disabled"
        case .highConnectionLimit: return "High Connection Limit"
        case .longTimeout: return "Long Connection Timeout"
        }
    }

    var message: String {
        switch self {
        case .passwordEnabledButEmpty: return "Password protection is enabled but no password is set. Set a password or disable protection."
        case .tlsDisabled: return "TLS encryption is disabled. Connections are not encrypted."
        case .highConnectionLimit: return "Connection limit is high. This may impact performance."
        case .longTimeout: return "Connection timeout is longer than recommended."
        }
    }

    var severity: SecurityWarningSeverity {
        switch self {
        case .passwordEnabledButEmpty: return .critical
        case .tlsDisabled: return .warning
        case .highConnectionLimit: return .info
        case .longTimeout: return .info
        }
    }
}

enum SecurityWarningSeverity: Sendable {
    case info
    case warning
    case critical
}
