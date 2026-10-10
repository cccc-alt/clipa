import AppKit
import Foundation

enum IntegrationProbe {
    @MainActor
    static func run() async -> Int32 {
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ label: String) {
            checks += 1
            if !ok { failures += 1 }
            print("[INTEGRATIONS] \(ok ? "PASS" : "FAIL") \(label)")
        }
        let root = ClipStore.defaultBaseDirectory()
        let suite = "ClipaIntegrationProbe-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            let settings = SettingsStore(defaults: defaults)
            settings.apiControlEnabled = true
            settings.historyLimit = 0
            let registry = WorkspaceStore.shared
            let firstID = registry.activeID
            let store = ClipStore(baseDirectory: root, settingsStore: settings)
            guard let db = store.database else { throw WorkflowError.message("isolated database failed") }
            let tokens = APITokenStore.shared
            tokens.reload()
            let meta = try tokens.create(label: "meta", scopes: [.searchMeta], workspaceIDs: [firstID])
            let full = try tokens.create(label: "full", scopes: APIToken.Scope.allCases, workspaceIDs: [firstID])
            let preview = try tokens.create(label: "preview", scopes: [.searchMeta, .searchText], workspaceIDs: [firstID])
            let fixtures = store.replaceAllForTesting([
                NewClip(kind: .text, text: "project reference alpha", note: "restricted note", sourceApp: "Safari"),
                NewClip(kind: .text, text: "project reference beta", sourceApp: "Xcode"),
                NewClip(kind: .text, text: "private project reference", note: "private note", isPrivate: true),
                NewClip(kind: .file, text: "", fileURLs: [URL(fileURLWithPath: "/isolated/file.txt")], sourceApp: "Finder")
            ])
            let publicClip = fixtures.first { $0.text == "project reference alpha" }!
            let otherClip = fixtures.first { $0.text == "project reference beta" }!
            let privateClip = fixtures.first { $0.isPrivate }!
            let service = APIControlService(store: store, settings: settings, rootDirectory: root, copyClip: { _ in true }, workspaceID: firstID)
            func call(_ verb: String, _ secret: String, _ arguments: APIRequest.Arguments = .init()) async -> APIResponse {
                var request = APIRequest(); request.verb = verb; request.token = secret; request.args = arguments
                return await service.handle(request, peer: "isolated-probe")
            }
            let metadata = await call("search", meta.secret)
            check(metadata.ok && metadata.results?.allSatisfy { $0.text.isEmpty && $0.note.isEmpty } == true, "metadata grant cannot read text or notes")
            let previews = await call("search", preview.secret)
            check(previews.results?.allSatisfy { $0.note.isEmpty } == true, "preview grant cannot read notes")
            let contents = await call("search", full.secret)
            check(contents.results?.contains { $0.note == "restricted note" } == true, "full-read grant can read permitted notes")
            check(contents.results?.contains { $0.id == privateClip.id.uuidString } == false, "private records never enter results")
            let status = await call("status", full.secret)
            check(status.status?.clipCount == 3, "status count excludes private records")
            var filter = APIRequest.Arguments(); filter.kind = "text"; filter.source = "Safari"
            filter.after = "2000-01-01T00:00:00Z"; filter.before = "2100-01-01T00:00:00Z"
            let filtered = await call("search", full.secret, filter)
            check(filtered.results?.map(\.id) == [publicClip.id.uuidString], "structured kind, source and time filters combine")
            filter.after = "invalid-date"
            check((await call("search", full.secret, filter)).error?.code == "bad_request", "malformed time never falls back to broad search")
            filter = .init(); filter.kind = "unknown"
            check((await call("search", full.secret, filter)).error?.code == "bad_request", "invalid type fails explicitly")

            let legacy = try tokens.create(label: "legacy", scopes: [.searchMeta])
            let tokenURL = APITokenStore.url(rootDirectory: root)
            var serialized = try JSONSerialization.jsonObject(with: Data(contentsOf: tokenURL)) as! [[String: Any]]
            for index in serialized.indices where serialized[index]["id"] as? String == legacy.token.id { serialized[index].removeValue(forKey: "workspaceIDs") }
            try OwnerOnlyFile.write(JSONSerialization.data(withJSONObject: serialized), to: tokenURL)
            tokens.reload()
            check((await call("search", legacy.secret)).error?.code == "authorization_required", "legacy grants fail closed until workspace confirmation")
            try tokens.updateAuthorization(id: legacy.token.id, scopes: [.searchMeta], workspaceIDs: [firstID], expiresAt: nil)
            check((await call("search", legacy.secret)).ok, "explicit workspace confirmation restores the existing manual credential")
            let expired = try tokens.create(label: "expired", scopes: [.searchMeta], expiresAt: Date().addingTimeInterval(-1))
            check((await call("status", expired.secret)).error?.code == "token_expired", "expired grants have an actionable error code")
            let beforeDiagnostic = tokens.tokens.first { $0.id == full.token.id }!.callCount
            let diagnosis = await call("diagnose", full.secret)
            check(diagnosis.ok && diagnosis.status == nil && diagnosis.count == nil, "diagnostics disclose no workspace metadata or counts")
            check(tokens.tokens.first { $0.id == full.token.id }!.callCount == beforeDiagnostic, "local diagnostics do not pretend to be client usage")

            let second = try registry.createWorkspace(named: "Second")
            let secondDB = try DatabaseManager(baseDirectory: registry.baseDirectory(for: second))
            let remote = try await secondDB.insertClip(NewClip(kind: .text, text: "remote reference", note: "remote note", sourceApp: "Xcode")).clip
            let remotePrivate = try await secondDB.insertClip(NewClip(kind: .text, text: "remote private", isPrivate: true)).clip
            let secondGrant = try tokens.create(label: "second", scopes: APIToken.Scope.allCases, workspaceIDs: [second.id])
            var remoteArgs = APIRequest.Arguments(); remoteArgs.workspaceID = second.id
            check((await call("search", full.secret, remoteArgs)).error?.code == "workspace_denied", "explicit requests cannot escape workspace authorization")
            let remoteResult = await call("search", secondGrant.secret)
            check(remoteResult.results?.map(\.id) == [remote.id.uuidString], "fixed grant reads its inactive workspace without switching UI")
            check(registry.activeID == firstID && remoteResult.results?.contains { $0.id == remotePrivate.id.uuidString } == false,
                  "inactive reads preserve active workspace and private exclusion")
            let otherStore = ClipStore(baseDirectory: registry.baseDirectory(for: second), settingsStore: settings)
            let rebound = APIControlService(store: otherStore, settings: settings, rootDirectory: root, copyClip: { _ in true }, workspaceID: second.id)
            var boundRequest = APIRequest(); boundRequest.token = meta.secret; boundRequest.verb = "search"
            let reboundResponse = await rebound.handle(boundRequest, peer: "isolated")
            check(reboundResponse.workspaceID == firstID && reboundResponse.results?.allSatisfy { $0.id != remote.id.uuidString } == true,
                  "switching UI never redirects a grant to a different workspace")
            let longBody = String(repeating: "参考🙂资料👩‍💻", count: 70)
            let longRemote = try await secondDB.insertClip(NewClip(kind: .text, text: longBody)).clip
            var pageArgs = APIRequest.Arguments(); pageArgs.id = longRemote.id.uuidString; pageArgs.maxBytes = 256
            var recovered = "", pageCount = 0
            while pageCount < 20 {
                let page = await call("get", secondGrant.secret, pageArgs)
                guard page.ok, let text = page.clip?.text else { break }
                check(text.utf8.count <= 256, "content page obeys byte budget")
                recovered += text; pageCount += 1
                guard let next = page.nextByteOffset else { break }
                pageArgs.byteOffset = next
            }
            check(recovered == longBody, "UTF-8 paging reconstructs emoji and CJK exactly")
            pageArgs.byteOffset = 1
            check(!(await call("get", secondGrant.secret, pageArgs)).ok, "mid-scalar offsets are rejected")
            var noteArgs = APIRequest.Arguments(); noteArgs.field = "note"; noteArgs.id = remote.id.uuidString
            let remoteNote = await call("get", secondGrant.secret, noteArgs)
            check(remoteNote.field == "note" && remoteNote.clip?.note == "remote note" && remoteNote.clip?.text == "",
                  "inactive notes can be read explicitly without mixing in body text")
            noteArgs.id = publicClip.id.uuidString
            let localNote = await call("get", full.secret, noteArgs)
            check(localNote.field == "note" && localNote.clip?.note == "restricted note", "active notes support the same paged contract")
            check((await call("get", preview.secret, noteArgs)).error?.code == "not_authorized", "note paging still requires full-read authorization")

            var collectionArgs = APIRequest.Arguments(); collectionArgs.name = "Project references"
            let created = await call("collection-create", full.secret, collectionArgs)
            guard let collection = created.collectionID else { throw WorkflowError.message("collection creation failed") }
            collectionArgs.collectionID = collection
            collectionArgs.ids = [publicClip.id.uuidString, privateClip.id.uuidString]
            check(!(await call("collection-add", full.secret, collectionArgs)).ok, "mixed private/public batch is rejected")
            check(try await db.collectionMembers(id: collection).isEmpty, "failed batch leaves no partial membership")
            collectionArgs.ids = [publicClip.id.uuidString, otherClip.id.uuidString, publicClip.id.uuidString]
            check((await call("collection-add", full.secret, collectionArgs)).ok, "batch collection addition succeeds")
            check(try await db.collectionMembers(id: collection).count == 2, "duplicate membership is idempotent")
            var collectionFilter = APIRequest.Arguments(); collectionFilter.collectionID = collection
            check((await call("search", full.secret, collectionFilter)).results?.count == 2, "collection search intersects ordinary visibility rules")
            check((await call("search", meta.secret, collectionFilter)).error?.code == "not_authorized", "collection filtering requires collection-read scope")
            _ = store.togglePrivate(otherClip)
            check(try await db.collectionMembers(id: collection) == [publicClip.id], "newly-private members disappear immediately")
            let beforeDelete = store.items.count
            check((await call("collection-delete", full.secret, collectionArgs)).ok && store.items.count == beforeDelete,
                  "deleting a collection preserves clipboard history")
            let encryptedName = "encrypted-collection-" + UUID().uuidString
            _ = try await db.saveCollection(name: encryptedName)
            let encrypted = try Data(contentsOf: DatabaseManager.databaseURL(in: root))
            check(encrypted.range(of: Data(encryptedName.utf8)) == nil, "collection names remain inside encrypted storage")

            let credentialID = UUID()
            let credential = ClientCredential(id: credentialID, tokenID: meta.token.id, client: .cursor, secret: meta.secret, createdAt: Date())
            try ClientCredentials.write(credential, root: root)
            check(try ClientCredentials.read(credentialID, root: root).secret == meta.secret, "managed credential round-trip succeeds")
            let credentialPath = ClientCredentials.url(credentialID, root: root)
            check(OwnerOnlyFile.isOwnerOnly(at: credentialPath), "managed credentials are owner-only")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: credentialPath.path)
            check((try? ClientCredentials.read(credentialID, root: root)) == nil, "over-permissive credential files are rejected")
            try ClientCredentials.write(credential, root: root)

            let home = root.appendingPathComponent("test-home")
            let configPath = IntegrationClient.cursor.configURL(home: home)!
            let original: [String: Any] = ["theme": "unchanged", "mcpServers": ["other": ["command": "other-helper"]]]
            try OwnerOnlyFile.write(JSONSerialization.data(withJSONObject: original), to: configPath)
            let helper = root.appendingPathComponent("Clipa.app/Contents/Helpers/clipa-mcp")
            try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let installed = try ClientConfigurationInstaller.install(client: .cursor, id: credentialID, helper: helper, replaceExisting: false, home: home)
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configPath)) as! [String: Any]
            let servers = config["mcpServers"] as! [String: Any]
            check(config["theme"] as? String == "unchanged" && servers["other"] != nil, "one-click install preserves unrelated client settings")
            check(installed.backup.map { OwnerOnlyFile.isOwnerOnly(at: $0) } == true, "existing client config gets an owner-only backup")
            check(!(try String(contentsOf: configPath)).contains(meta.secret), "client config never contains the token")
            let saved = try Data(contentsOf: configPath)
            let refused = try? ClientConfigurationInstaller.install(client: .cursor, id: UUID(), helper: helper, replaceExisting: false, home: home)
            let afterRefusal = try Data(contentsOf: configPath)
            check(refused == nil && afterRefusal == saved, "existing Clipa entry needs explicit replacement")
            try Data("broken json".utf8).write(to: configPath)
            check((try? ClientConfigurationInstaller.install(client: .cursor, id: credentialID, helper: helper, replaceExisting: true, home: home)) == nil,
                  "invalid client config is not overwritten")
            try saved.write(to: configPath)

            var codexInstalled = false
            let codex = try ClientConfigurationInstaller.install(client: .codex, id: credentialID, helper: helper,
                replaceExisting: false, home: home, codexCLI: URL(fileURLWithPath: "/mock/codex"), runner: { _, arguments in
                    if arguments.prefix(2) == ["mcp", "add"] {
                        guard arguments.contains("CLIPA_CONNECTION=" + credentialID.uuidString), arguments.last == helper.path else {
                            throw WorkflowError.message("incorrect Codex arguments")
                        }
                        codexInstalled = true; return (0, Data())
                    }
                    if !codexInstalled { return (1, Data()) }
                    return (0, try JSONSerialization.data(withJSONObject: ["transport": ["command": helper.path, "env": ["CLIPA_CONNECTION": credentialID.uuidString]]]))
                })
            check(codexInstalled && codex.destination != nil, "Codex uses its native CLI and verifies the stored profile")
            let specialHelper = URL(fileURLWithPath: "/Applications/Quoted \"App\"/clipa-mcp")
            let copiedCodex = ClientConfigurationInstaller.config(id: credentialID, helper: specialHelper, codex: true)
            check(!copiedCodex.contains("\\/") && copiedCodex.contains("\\\"App\\\""), "copied Codex TOML escapes quotes without invalid slash escapes")

            let management = ManagementModel(settings: settings, registry: registry, tokenStore: tokens, store: store,
                switchWorkspace: { _ in store }, changeAPI: { settings.apiControlEnabled = $0 }, apiIsRunning: { true })
            management.helperBundleURL = root.appendingPathComponent("Clipa.app")
            management.installClientConfiguration = { client, id, helper, replace in
                try ClientConfigurationInstaller.install(client: client, id: id, helper: helper, replaceExisting: replace, home: home)
            }
            func wait() async {
                for _ in 0..<400 { if !management.isBusy { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
            }
            management.present(.connect(.claude, nil))
            management.connectClient(.claude, existingID: nil, scopes: [.searchMeta], workspaceIDs: [firstID], days: 30, replaceExisting: false)
            await wait()
            let managed = tokens.tokens.first { $0.connectionID != nil && $0.label == "Claude Desktop" }
            check(managed != nil && management.sheetError == nil, "connection workflow issues a workspace-bound managed grant")
            if let managed, let profile = managed.connectionID {
                let old = try ClientCredentials.read(profile, root: root).secret
                management.dismissSheet()
                management.present(.connect(.claude, managed.id))
                management.connectClient(.claude, existingID: managed.id, scopes: [.searchMeta], workspaceIDs: [firstID], days: 90, replaceExisting: true)
                await wait()
                let replacement = try ClientCredentials.read(profile, root: root).secret
                check(tokens.verify(secret: old) == nil && tokens.verify(secret: replacement) != nil && old != replacement,
                      "reconnect rotates credentials and invalidates the old secret")
                management.dismissSheet()
                let revoke = ManagementConfirmation(title: "revoke", detail: "isolated", button: "revoke", action: .revoke(managed.id))
                management.present(.confirmation(revoke)); management.execute(revoke)
                await wait()
                check(tokens.verify(secret: replacement) == nil && !FileManager.default.fileExists(atPath: ClientCredentials.url(profile, root: root).path),
                      "revocation invalidates managed authorization and removes its credential")
            }
            do { try tokens.rotate(id: meta.token.id) { _ in throw WorkflowError.message("simulated credential write failure") } }
            catch { }
            check(tokens.verify(secret: meta.secret) != nil, "failed credential persistence restores the previous token hash")
            let anonymousTools = APIMcp.toolDefinitions(scopes: nil).compactMap { $0["name"] as? String }
            check(Set(anonymousTools) == ["clipa_status", "clipa_diagnose", "clipa_reconnect"], "unauthorized MCP discovery exposes only recovery tools")
            let metaTools = APIMcp.toolDefinitions(scopes: ["search.meta"]).compactMap { $0["name"] as? String }
            check(metaTools.contains("search_clips") && !metaTools.contains("delete_clip") && !metaTools.contains("get_clip"), "MCP tools reflect granted capabilities")
            let fullTools = APIMcp.toolDefinitions(scopes: Set(APIToken.Scope.allCases.map(\.rawValue)))
            check(fullTools.count == 16 && fullTools.allSatisfy { $0["annotations"] != nil && $0["outputSchema"] != nil },
                  "all tools expose safety hints and structured output schemas")

            let server = APIControlServer()
            server.start(store: store, settings: settings, rootDirectory: root)
            defer { server.stop() }
            check(server.isRunning, "isolated transport starts")
            let socketURL = APIControlServer.socketURL(rootDirectory: root)
            var wireRequest = APIRequest(); wireRequest.verb = "search"; wireRequest.token = full.secret
            wireRequest.args.workspaceID = second.id
            let toSend = wireRequest
            let wireResponse: APIResponse? = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: APIClientCLI.send(toSend, to: socketURL, timeout: 3))
                }
            }
            check(wireResponse?.error?.code == "workspace_denied", "wire workspace_id is decoded and enforced, never silently ignored")
            var uuidResponse = APIResponse(ok: true, schema: 1)
            uuidResponse.workspaceID = firstID; uuidResponse.collectionID = collection
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let roundTrip = try decoder.decode(APIResponse.self, from: Data(APIClientCLI.jsonString(for: uuidResponse).utf8))
            check(roundTrip.workspaceID == firstID && roundTrip.collectionID == collection, "UUID fields survive snake-case serialization")
            let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            let requests = [
                #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_clips","arguments":{"query":"--help"}}}"#,
                #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_clip","arguments":{"id":""}}}"#,
                #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_clips","arguments":{"limit":1e100}}}"#
            ].joined(separator: "\n") + "\n"
                + #"{"jsonrpc":"2.0","id":5,"method":"ping"}"# + String(repeating: " ", count: 70 * 1024) + "\n"
                + #"{"jsonrpc":"2.0","id":6,"method":"ping"}"# + "\n"
            let probeSecret = meta.secret
            let mcpData: Data = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let process = Process(); process.executableURL = executable
                    process.arguments = ["--mcp-test-stdio", root.path]
                    var environment = ProcessInfo.processInfo.environment
                    environment["CLIPA_TOKEN"] = probeSecret; environment.removeValue(forKey: "CLIPA_CONNECTION")
                    process.environment = environment
                    let input = Pipe(), output = Pipe()
                    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                        input.fileHandleForWriting.write(Data(requests.utf8)); input.fileHandleForWriting.closeFile()
                        let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                        continuation.resume(returning: result)
                    } catch { continuation.resume(returning: Data()) }
                }
            }
            let rpc = mcpData.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            let advertised = ((rpc.first?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
            check(advertised.contains { $0["name"] as? String == "search_clips" }, "real MCP bridge discovers authenticated scopes")
            let searchResult = rpc.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any]
            let structured = searchResult?["structuredContent"] as? [String: Any]
            check(structured?["ok"] as? Bool == true && structured?["count"] as? Int == 0,
                  "literal option-like search text stays data and structured content is returned")
            check((rpc.first { $0["id"] as? Int == 3 }?["result"] as? [String: Any])?["isError"] as? Bool == true,
                  "calling an unadvertised full-read tool still fails server authorization")
            check((rpc.first { $0["id"] as? Int == 4 }?["result"] as? [String: Any])?["isError"] as? Bool == true,
                  "oversized numeric parameters are rejected without integer overflow")
            check(rpc.contains { ($0["error"] as? [String: Any])?["code"] as? Int == -32700 }, "oversized JSON lines are rejected rather than executing a valid truncated prefix")
            check(rpc.first { $0["id"] as? Int == 6 }?["result"] != nil, "MCP reader recovers after draining an oversized line")
        } catch {
            check(false, "unexpected error: " + error.localizedDescription)
        }
        print("[INTEGRATIONS] \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }
}
