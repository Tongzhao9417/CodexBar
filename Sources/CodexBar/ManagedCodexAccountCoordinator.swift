import CodexBarCore
import Foundation
import Observation

enum ManagedCodexAccountCoordinatorError: Error, Equatable {
    case authenticationInProgress
}

@MainActor
@Observable
final class ManagedCodexAccountCoordinator {
    let service: ManagedCodexAccountService
    private(set) var isAuthenticatingManagedAccount: Bool = false
    private(set) var authenticatingManagedAccountID: UUID?
    private(set) var isImportingManagedAccount: Bool = false
    private(set) var isRemovingManagedAccount: Bool = false
    private(set) var removingManagedAccountID: UUID?
    var onManagedAccountsDidChange: (@MainActor () -> Void)?

    var hasConflictingManagedAccountOperationInFlight: Bool {
        self.isAuthenticatingManagedAccount || self.isImportingManagedAccount || self.isRemovingManagedAccount
    }

    init(service: ManagedCodexAccountService = ManagedCodexAccountService()) {
        self.service = service
    }

    func authenticateManagedAccount(
        existingAccountID: UUID? = nil,
        timeout: TimeInterval = 120)
        async throws -> ManagedCodexAccount
    {
        guard self.isAuthenticatingManagedAccount == false else {
            throw ManagedCodexAccountCoordinatorError.authenticationInProgress
        }

        self.isAuthenticatingManagedAccount = true
        self.authenticatingManagedAccountID = existingAccountID
        defer {
            self.isAuthenticatingManagedAccount = false
            self.authenticatingManagedAccountID = nil
        }

        let account = try await self.service.authenticateManagedAccount(
            existingAccountID: existingAccountID,
            timeout: timeout)
        self.onManagedAccountsDidChange?()
        return account
    }

    func importSub2APIAccounts(from url: URL) async throws -> Sub2APIImportSummary {
        guard self.hasConflictingManagedAccountOperationInFlight == false else {
            throw ManagedCodexAccountCoordinatorError.authenticationInProgress
        }

        self.isImportingManagedAccount = true
        defer {
            self.isImportingManagedAccount = false
        }

        let summary = try Sub2APIAccountImporter().importAccounts(from: url)
        self.onManagedAccountsDidChange?()
        return summary
    }

    func removeManagedAccount(id: UUID) async throws {
        guard self.hasConflictingManagedAccountOperationInFlight == false else {
            throw ManagedCodexAccountCoordinatorError.authenticationInProgress
        }

        self.isRemovingManagedAccount = true
        self.removingManagedAccountID = id
        defer {
            self.isRemovingManagedAccount = false
            self.removingManagedAccountID = nil
        }

        try await self.service.removeManagedAccount(id: id)
        self.onManagedAccountsDidChange?()
    }
}
