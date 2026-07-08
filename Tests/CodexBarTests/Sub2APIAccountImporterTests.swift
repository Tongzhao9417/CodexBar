import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct Sub2APIAccountImporterTests {
    @Test
    func `imports openai oauth account and writes readable codex auth`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let accountID = "00000000-0000-0000-0000-000000000000"
        let data = Self.makeExportData(
            name: "User@Example.com",
            accessToken: Self.fakeJWT(email: "ignored@example.com", accountID: accountID, plan: "pro"),
            refreshToken: "refresh-token-one",
            accountID: accountID,
            plan: "team")

        let importer = Self.makeImporter(env: env)
        let summary = try importer.importAccounts(from: data)
        let stored = try env.store.loadAccounts()
        let imported = try #require(summary.importedAccounts.first?.account)
        let credentials = try CodexOAuthCredentialsStore.load(env: ["CODEX_HOME": imported.managedHomePath])

        #expect(summary.importedAccounts.count == 1)
        #expect(summary.createdCount == 1)
        #expect(summary.updatedCount == 0)
        #expect(summary.skippedAccountCount == 1)
        #expect(stored.accounts.count == 1)
        #expect(imported.email == "user@example.com")
        #expect(imported.providerAccountID == accountID)
        #expect(imported.workspaceLabel == "team")
        #expect(imported.authFingerprint != nil)
        #expect(credentials.accessToken.contains("."))
        #expect(credentials.refreshToken == "refresh-token-one")
        #expect(credentials.accountId == accountID)
        #expect(credentials.idToken == credentials.accessToken)
        #expect(credentials.lastRefresh == Self.exportedAt)
    }

    @Test
    func `falls back to jwt claims for email plan and account id`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let accountID = "workspace-team"
        let idToken = Self.fakeJWT(email: "jwt@example.com", accountID: accountID, plan: "team")
        let data = Self.makeExportData(
            name: "Display Name",
            accessToken: "access-token-two",
            refreshToken: "refresh-token-two",
            accountID: nil,
            idToken: idToken,
            plan: nil)

        let summary = try Self.makeImporter(env: env).importAccounts(from: data)
        let account = try #require(summary.importedAccounts.first?.account)
        let credentials = try CodexOAuthCredentialsStore.load(env: ["CODEX_HOME": account.managedHomePath])

        #expect(account.email == "jwt@example.com")
        #expect(account.providerAccountID == accountID)
        #expect(account.workspaceLabel == "team")
        #expect(credentials.accessToken == "access-token-two")
        #expect(credentials.refreshToken == "refresh-token-two")
        #expect(credentials.idToken == idToken)
        #expect(credentials.accountId == accountID)
    }

    @Test
    func `reimport updates matching account without creating duplicates`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let accountID = "workspace-team"
        let importer = Self.makeImporter(env: env)
        let first = try importer.importAccounts(from: Self.makeExportData(
            name: "user@example.com",
            accessToken: "access-token-first",
            refreshToken: "refresh-token-first",
            accountID: accountID,
            plan: "team"))
        let firstAccount = try #require(first.importedAccounts.first?.account)
        let firstFingerprint = try #require(firstAccount.authFingerprint)

        let second = try importer.importAccounts(from: Self.makeExportData(
            name: "USER@example.com",
            accessToken: "access-token-second",
            refreshToken: "refresh-token-second",
            accountID: accountID,
            plan: "team"))
        let secondAccount = try #require(second.importedAccounts.first?.account)
        let stored = try env.store.loadAccounts()
        let credentials = try CodexOAuthCredentialsStore.load(env: ["CODEX_HOME": secondAccount.managedHomePath])

        #expect(second.updatedCount == 1)
        #expect(stored.accounts.count == 1)
        #expect(firstAccount.id == secondAccount.id)
        #expect(firstAccount.managedHomePath == secondAccount.managedHomePath)
        #expect(secondAccount.authFingerprint != firstFingerprint)
        #expect(credentials.accessToken == "access-token-second")
        #expect(credentials.refreshToken == "refresh-token-second")
    }

    @Test
    func `throws clear error when no openai oauth accounts exist`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let json = """
        {
          "accounts": [
            {
              "platform": "anthropic",
              "type": "oauth",
              "name": "claude@example.com",
              "credentials": {
                "access_token": "access-token",
                "refresh_token": "refresh-token"
              }
            }
          ]
        }
        """

        #expect(throws: Sub2APIAccountImporterError.noImportableAccounts) {
            try Self.makeImporter(env: env).importAccounts(from: Data(json.utf8))
        }
    }

    @Test
    func `throws clear error when required token is missing`() throws {
        let env = try Self.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.root) }

        let json = """
        {
          "accounts": [
            {
              "platform": "openai",
              "type": "oauth",
              "name": "user@example.com",
              "credentials": {
                "refresh_token": "refresh-token",
                "chatgpt_account_id": "workspace-team"
              }
            }
          ]
        }
        """

        #expect(throws: Sub2APIAccountImporterError.missingAccessToken(account: "user@example.com")) {
            try Self.makeImporter(env: env).importAccounts(from: Data(json.utf8))
        }
    }

    private static let exportedAt = ISO8601DateFormatter().date(from: "2026-06-07T06:23:57Z")!

    private static func makeEnvironment() throws -> TestEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-sub2api-import-\(UUID().uuidString)", isDirectory: true)
        let storeURL = root.appendingPathComponent("managed-codex-accounts.json", isDirectory: false)
        let homesRoot = root.appendingPathComponent("managed-codex-homes", isDirectory: true)
        try FileManager.default.createDirectory(at: homesRoot, withIntermediateDirectories: true)
        return TestEnvironment(
            root: root,
            homesRoot: homesRoot,
            store: FileManagedCodexAccountStore(fileURL: storeURL))
    }

    private static func makeImporter(env: TestEnvironment) -> Sub2APIAccountImporter {
        Sub2APIAccountImporter(
            store: env.store,
            managedHomeRootURL: env.homesRoot,
            now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    private static func makeExportData(
        name: String,
        accessToken: String,
        refreshToken: String,
        accountID: String?,
        idToken: String? = nil,
        plan: String?)
        -> Data
    {
        var credentials: [String: Any] = [
            "access_token": accessToken,
            "refresh_token": refreshToken,
        ]
        if let accountID {
            credentials["chatgpt_account_id"] = accountID
        }
        if let idToken {
            credentials["id_token"] = idToken
        }
        if let plan {
            credentials["plan_type"] = plan
        }
        let object: [String: Any] = [
            "exported_at": "2026-06-07T06:23:57Z",
            "accounts": [
                [
                    "platform": "openai",
                    "type": "oauth",
                    "name": name,
                    "credentials": credentials,
                ],
                [
                    "platform": "other",
                    "type": "oauth",
                    "name": "ignored@example.com",
                    "credentials": credentials,
                ],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private static func fakeJWT(email: String, accountID: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
                "chatgpt_plan_type": plan,
            ],
        ])) ?? Data()
        return "\(Self.base64URL(header)).\(Self.base64URL(payload))."
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}

private struct TestEnvironment {
    let root: URL
    let homesRoot: URL
    let store: FileManagedCodexAccountStore
}
