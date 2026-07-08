import Crypto
import Foundation

public enum CodexManagedHomePaths {
    public static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("managed-codex-homes", isDirectory: true)
    }
}

public struct Sub2APIImportSummary: Sendable {
    public let importedAccounts: [Sub2APIImportedAccount]
    public let skippedAccountCount: Int

    public init(importedAccounts: [Sub2APIImportedAccount], skippedAccountCount: Int) {
        self.importedAccounts = importedAccounts
        self.skippedAccountCount = skippedAccountCount
    }

    public var createdCount: Int {
        self.importedAccounts.count(where: { !$0.updatedExistingAccount })
    }

    public var updatedCount: Int {
        self.importedAccounts.filter(\.updatedExistingAccount).count
    }
}

public struct Sub2APIImportedAccount: Sendable {
    public let account: ManagedCodexAccount
    public let updatedExistingAccount: Bool

    public init(account: ManagedCodexAccount, updatedExistingAccount: Bool) {
        self.account = account
        self.updatedExistingAccount = updatedExistingAccount
    }
}

public enum Sub2APIAccountImporterError: LocalizedError, Equatable, Sendable {
    case invalidJSON(String)
    case noImportableAccounts
    case missingCredentials(account: String)
    case missingAccessToken(account: String)
    case missingRefreshToken(account: String)
    case missingAccountID(account: String)
    case missingEmail(account: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidJSON(message):
            "Could not read sub2api JSON: \(message)"
        case .noImportableAccounts:
            "No importable OpenAI OAuth accounts found."
        case let .missingCredentials(account):
            "\(account) is missing credentials."
        case let .missingAccessToken(account):
            "\(account) is missing access_token."
        case let .missingRefreshToken(account):
            "\(account) is missing refresh_token."
        case let .missingAccountID(account):
            "\(account) is missing chatgpt_account_id."
        case let .missingEmail(account):
            "\(account) is missing an email address."
        }
    }
}

public struct Sub2APIAccountImporter {
    private let store: any ManagedCodexAccountStoring
    private let managedHomeRootURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    public init(
        store: any ManagedCodexAccountStoring = FileManagedCodexAccountStore(),
        managedHomeRootURL: URL = CodexManagedHomePaths.defaultRootURL(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.store = store
        self.managedHomeRootURL = managedHomeRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    public func importAccounts(from url: URL) throws -> Sub2APIImportSummary {
        let data = try Data(contentsOf: url)
        return try self.importAccounts(from: data)
    }

    public func importAccounts(from data: Data) throws -> Sub2APIImportSummary {
        let export = try self.decodeExport(from: data)
        let importableAccounts = export.accounts.enumerated().filter { _, account in
            Self.matches(account.platform, expected: "openai") && Self.matches(account.type, expected: "oauth")
        }
        guard !importableAccounts.isEmpty else {
            throw Sub2APIAccountImporterError.noImportableAccounts
        }

        let resolvedAccounts = try importableAccounts.map { index, account in
            try self.resolvedAccount(account, index: index, exportedAt: export.exportedAt)
        }
        let snapshot = try self.store.loadAccounts()
        var accounts = snapshot.accounts
        var imported: [Sub2APIImportedAccount] = []
        imported.reserveCapacity(resolvedAccounts.count)

        for resolved in resolvedAccounts {
            let existing = self.existingAccount(
                in: accounts,
                email: resolved.email,
                providerAccountID: resolved.providerAccountID,
                deterministicID: resolved.deterministicID)
            let targetID = existing?.id ?? resolved.deterministicID
            let homeURL = self.homeURL(existingAccount: existing, accountID: targetID)
            try self.writeCredentials(resolved.credentials, to: homeURL)
            let fingerprint = CodexAuthFingerprint.fingerprint(homePath: homeURL.path, fileManager: self.fileManager)
            let timestamp = self.now().timeIntervalSince1970
            let updated = ManagedCodexAccount(
                id: targetID,
                email: resolved.email,
                providerAccountID: resolved.providerAccountID,
                workspaceLabel: resolved.workspaceLabel ?? existing?.workspaceLabel,
                workspaceAccountID: resolved.providerAccountID,
                authFingerprint: fingerprint,
                managedHomePath: homeURL.path,
                createdAt: existing?.createdAt ?? timestamp,
                updatedAt: timestamp,
                lastAuthenticatedAt: timestamp)

            let replacedIDs = self.replacedAccountIDs(
                existingAccount: existing,
                importedAccount: updated,
                accounts: accounts)
            accounts.removeAll { replacedIDs.contains($0.id) }
            accounts.append(updated)
            imported.append(Sub2APIImportedAccount(
                account: updated,
                updatedExistingAccount: existing != nil))
        }

        try self.store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: accounts))

        return Sub2APIImportSummary(
            importedAccounts: imported,
            skippedAccountCount: export.accounts.count - importableAccounts.count)
    }

    private func decodeExport(from data: Data) throws -> Sub2APIExport {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Sub2APIExport.self, from: data)
        } catch let exportError {
            do {
                let accounts = try decoder.decode([Sub2APIAccount].self, from: data)
                return Sub2APIExport(exportedAt: nil, accounts: accounts)
            } catch {
                throw Sub2APIAccountImporterError.invalidJSON(exportError.localizedDescription)
            }
        }
    }

    private func resolvedAccount(
        _ account: Sub2APIAccount,
        index: Int,
        exportedAt: Date?)
        throws -> ResolvedImportAccount
    {
        let label = Self.accountLabel(account, index: index)
        guard let credentials = account.credentials else {
            throw Sub2APIAccountImporterError.missingCredentials(account: label)
        }
        guard let accessToken = credentials.accessToken else {
            throw Sub2APIAccountImporterError.missingAccessToken(account: label)
        }
        guard let refreshToken = credentials.refreshToken else {
            throw Sub2APIAccountImporterError.missingRefreshToken(account: label)
        }

        let idToken = credentials.idToken ?? accessToken
        let jwtPayload = UsageFetcher.parseJWT(idToken)
        let authClaims = jwtPayload?["https://api.openai.com/auth"] as? [String: Any]
        let profileClaims = jwtPayload?["https://api.openai.com/profile"] as? [String: Any]
        let providerAccountID = ManagedCodexAccount.normalizeProviderAccountID(
            credentials.chatGPTAccountID
                ?? credentials.accountID
                ?? (authClaims?["chatgpt_account_id"] as? String)
                ?? (jwtPayload?["chatgpt_account_id"] as? String))
        guard let providerAccountID else {
            throw Sub2APIAccountImporterError.missingAccountID(account: label)
        }

        let email = Self.firstNormalizedEmail([
            account.name,
            jwtPayload?["email"] as? String,
            profileClaims?["email"] as? String,
        ])
        guard let email else {
            throw Sub2APIAccountImporterError.missingEmail(account: label)
        }

        let workspaceLabel = ManagedCodexAccount.normalizeWorkspaceLabel(
            credentials.planType
                ?? (authClaims?["chatgpt_plan_type"] as? String)
                ?? (jwtPayload?["chatgpt_plan_type"] as? String))
        let oauthCredentials = CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: providerAccountID,
            lastRefresh: exportedAt ?? self.now())

        return ResolvedImportAccount(
            email: email,
            providerAccountID: providerAccountID,
            workspaceLabel: workspaceLabel,
            credentials: oauthCredentials,
            deterministicID: Self.deterministicID(email: email, providerAccountID: providerAccountID))
    }

    private func existingAccount(
        in accounts: [ManagedCodexAccount],
        email: String,
        providerAccountID: String,
        deterministicID: UUID)
        -> ManagedCodexAccount?
    {
        let normalizedEmail = ManagedCodexAccount.normalizeEmail(email)
        if let exact = accounts.first(where: {
            $0.email == normalizedEmail && $0.providerAccountID == providerAccountID
        }) {
            return exact
        }
        return accounts.first { $0.id == deterministicID }
    }

    private func replacedAccountIDs(
        existingAccount: ManagedCodexAccount?,
        importedAccount: ManagedCodexAccount,
        accounts: [ManagedCodexAccount])
        -> Set<UUID>
    {
        var ids: Set<UUID> = [importedAccount.id]
        if let existingAccount {
            ids.insert(existingAccount.id)
        }
        ids.formUnion(accounts
            .filter {
                $0.providerAccountID == nil &&
                    $0.email == importedAccount.email &&
                    $0.id != importedAccount.id
            }
            .map(\.id))
        return ids
    }

    private func homeURL(existingAccount: ManagedCodexAccount?, accountID: UUID) -> URL {
        if let existingPath = existingAccount?.managedHomePath.trimmingCharacters(in: .whitespacesAndNewlines),
           !existingPath.isEmpty
        {
            return URL(fileURLWithPath: existingPath, isDirectory: true).standardizedFileURL
        }
        return self.managedHomeRootURL.appendingPathComponent(accountID.uuidString, isDirectory: true)
    }

    private func writeCredentials(_ credentials: CodexOAuthCredentials, to homeURL: URL) throws {
        try self.fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try CodexOAuthCredentialsStore.save(credentials, env: ["CODEX_HOME": homeURL.path])
        #if os(macOS)
        try self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: homeURL.path)
        let authURL = CodexAuthFingerprint.authFileURL(homePath: homeURL.path)
        try self.fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: authURL.path)
        #endif
    }

    private static func accountLabel(_ account: Sub2APIAccount, index: Int) -> String {
        if let name = account.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "OpenAI OAuth account \(index + 1)"
    }

    private static func matches(_ value: String?, expected: String) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(expected) == .orderedSame
    }

    private static func normalizedEmail(_ email: String?) -> String? {
        guard let normalized = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty,
              normalized.contains("@")
        else {
            return nil
        }
        return normalized
    }

    private static func firstNormalizedEmail(_ candidates: [String?]) -> String? {
        candidates.lazy.compactMap(self.normalizedEmail).first
    }

    private static func deterministicID(email: String, providerAccountID: String) -> UUID {
        let input = "codexbar-sub2api:\(email.lowercased()):\(providerAccountID.lowercased())"
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7],
            bytes[8],
            bytes[9],
            bytes[10],
            bytes[11],
            bytes[12],
            bytes[13],
            bytes[14],
            bytes[15]))
    }
}

private struct ResolvedImportAccount {
    let email: String
    let providerAccountID: String
    let workspaceLabel: String?
    let credentials: CodexOAuthCredentials
    let deterministicID: UUID
}
