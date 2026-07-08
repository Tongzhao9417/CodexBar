import Foundation

public struct Sub2APIExport: Decodable, Sendable {
    public let exportedAt: Date?
    public let accounts: [Sub2APIAccount]

    enum CodingKeys: String, CodingKey {
        case exportedAt = "exported_at"
        case accounts
    }

    public init(exportedAt: Date?, accounts: [Sub2APIAccount]) {
        self.exportedAt = exportedAt
        self.accounts = accounts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.exportedAt = try container.decodeFlexibleDateIfPresent(forKey: .exportedAt)
        self.accounts = try container.decode([Sub2APIAccount].self, forKey: .accounts)
    }
}

public struct Sub2APIAccount: Decodable, Sendable {
    public let platform: String?
    public let type: String?
    public let name: String?
    public let credentials: Sub2APICredentials?

    public init(platform: String?, type: String?, name: String?, credentials: Sub2APICredentials?) {
        self.platform = platform
        self.type = type
        self.name = name
        self.credentials = credentials
    }
}

public struct Sub2APICredentials: Decodable, Sendable {
    public let accessToken: String?
    public let refreshToken: String?
    public let chatGPTAccountID: String?
    public let accountID: String?
    public let idToken: String?
    public let planType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessTokenCamel = "accessToken"
        case refreshToken = "refresh_token"
        case refreshTokenCamel = "refreshToken"
        case chatGPTAccountID = "chatgpt_account_id"
        case chatGPTAccountIDCamel = "chatgptAccountId"
        case accountID = "account_id"
        case accountIDCamel = "accountId"
        case idToken = "id_token"
        case idTokenCamel = "idToken"
        case planType = "plan_type"
        case planTypeCamel = "planType"
    }

    public init(
        accessToken: String?,
        refreshToken: String?,
        chatGPTAccountID: String?,
        accountID: String? = nil,
        idToken: String?,
        planType: String?)
    {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.chatGPTAccountID = chatGPTAccountID
        self.accountID = accountID
        self.idToken = idToken
        self.planType = planType
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accessToken = try container.decodeFirstNonEmptyString(keys: [.accessToken, .accessTokenCamel])
        self.refreshToken = try container.decodeFirstNonEmptyString(keys: [.refreshToken, .refreshTokenCamel])
        self.chatGPTAccountID = try container.decodeFirstNonEmptyString(
            keys: [.chatGPTAccountID, .chatGPTAccountIDCamel])
        self.accountID = try container.decodeFirstNonEmptyString(keys: [.accountID, .accountIDCamel])
        self.idToken = try container.decodeFirstNonEmptyString(keys: [.idToken, .idTokenCamel])
        self.planType = try container.decodeFirstNonEmptyString(keys: [.planType, .planTypeCamel])
    }
}

extension KeyedDecodingContainer {
    fileprivate func decodeFlexibleDateIfPresent(forKey key: Key) throws -> Date? {
        guard let raw = try self.decodeIfPresent(String.self, forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }
}

extension KeyedDecodingContainer where Key == Sub2APICredentials.CodingKeys {
    fileprivate func decodeFirstNonEmptyString(keys: [Key]) throws -> String? {
        for key in keys {
            guard let raw = try self.decodeIfPresent(String.self, forKey: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty
            else {
                continue
            }
            return raw
        }
        return nil
    }
}
