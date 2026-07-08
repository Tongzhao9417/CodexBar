import Foundation
import Testing
@testable import CodexBarCore

struct TailscaleSessionTests {
    @Test
    func `online mac and linux peers become hosts`() throws {
        let url = try AgentSessionParserTests.fixtureURL("agent-sessions-tailscale", extension: "json")
        let hosts = try TailscaleStatusParser.hosts(
            from: Data(contentsOf: url),
            excludingLocalHost: "local-mac")

        #expect(hosts == ["clawmac", "linuxbox"])
    }

    @Test
    func `ssh destinations reject options whitespace and controls`() {
        let hosts = RemoteSessionFetcher.sanitizedHosts([
            "user@clawmac",
            "USER@CLAWMAC",
            "-oProxyCommand=touch /tmp/unsafe",
            "host with-space",
            "host\nother",
            "linuxbox",
        ])

        #expect(hosts == ["user@clawmac", "linuxbox"])
    }

    @Test
    func `tailscale binary lookup uses path cli`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tailscale-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let binary = root.appendingPathComponent("tailscale")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let fetcher = RemoteSessionFetcher()
        #expect(fetcher.tailscaleBinary(environment: ["PATH": root.path]) == binary.path)
    }

    @Test
    func `tailscale binary lookup does not use app bundle executable`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tailscale-app-\(UUID().uuidString)", isDirectory: true)
        let appBinary = root
            .appendingPathComponent("Applications/Tailscale.app/Contents/MacOS", isDirectory: true)
            .appendingPathComponent("Tailscale")
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: appBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appBinary.path)
        let symlink = binDirectory.appendingPathComponent("tailscale")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: appBinary)

        let fetcher = RemoteSessionFetcher()
        #expect(fetcher.tailscaleBinary(environment: ["PATH": binDirectory.path]) == nil)
    }
}
