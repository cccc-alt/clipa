import AppKit
import Foundation

enum WorkflowProbe {
    @MainActor
    static func run() async -> Int32 {
        var checks = 0
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures += 1 }
            print("[WORKFLOW] \(ok ? "PASS" : "FAIL") \(name)")
        }
        func wait(_ model: ManagementModel) async {
            for _ in 0..<500 {
                if !model.isBusy { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            check(false, "operation completes within five seconds")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipaWorkflow-\(UUID())")
        let defaultsName = "ClipaWorkflow-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let previousTokens = APITokenStore.directoryOverride
        APITokenStore.directoryOverride = root
        defer {
            APITokenStore.directoryOverride = previousTokens
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        let settings = SettingsStore(defaults: defaults)
        settings.historyLimit = 100
        let registry = WorkspaceStore(rootDirectory: root)
        let store = ClipStore(baseDirectory: root, settingsStore: settings)
        let tokens = APITokenStore()
        let model = ManagementModel(
            settings: settings, registry: registry, tokenStore: tokens, store: store,
            switchWorkspace: { _ in throw WorkflowError.message("模拟打开失败") },
            changeAPI: { _ in throw WorkflowError.message("模拟接口启动失败") },
            apiIsRunning: { false }, authenticate: { _ in false }
        )
        check(WorkflowValidation.workspaceName(" ", existing: registry.workspaces) != nil, "blank workspace name is rejected")
        check(WorkflowValidation.workspaceName(registry.activeWorkspace.name, existing: registry.workspaces) != nil, "duplicate workspace name is rejected")
        check(WorkflowValidation.historyLimit("-1") == nil && WorkflowValidation.historyLimit("1.5") == nil
              && WorkflowValidation.historyLimit("1000001") == nil, "invalid limits are rejected without changing state")
        check(WorkflowValidation.historyLimit("5000") == 5000, "valid limit is accepted")
        check(WorkflowValidation.tokenName("") != nil, "unnamed authorization is rejected")
        model.present(.workspace(nil))
        model.saveWorkspace(name: " ", editing: nil, activate: false)
        check(model.sheet != nil && model.sheetError != nil && registry.workspaces.count == 1,
              "invalid form stays open and preserves registry")
        model.saveWorkspace(name: "项目", editing: nil, activate: false)
        await wait(model)
        check(registry.workspaces.count == 2 && model.sheet == nil, "successful creation closes only after persistence")
        let originalID = registry.activeID
        if let project = registry.workspaces.last {
            model.activate(project.id)
            await wait(model)
            check(registry.activeID == originalID && model.notice?.isError == true, "failed switch keeps active workspace and reports error")
        }
        model.setAPIEnabled(true)
        check(!settings.apiControlEnabled && model.notice?.isError == true, "failed interface start never shows an enabled switch")

        let seeded = store.replaceAllForTesting([
            NewClip(kind: .text, text: "private-fixture", isPrivate: true),
            NewClip(kind: .text, text: "public-one"),
            NewClip(kind: .text, text: "public-two")
        ])
        model.requestLimit(1)
        check(model.sheet != nil && store.items.count == 3 && settings.historyLimit == 100,
              "lower limit waits for explicit confirmation")
        model.dismissSheet()
        check(store.items.count == 3 && settings.historyLimit == 100, "cancelled limit leaves history and preference unchanged")
        model.requestClear()
        if case .confirmation(let confirmation) = model.sheet {
            model.execute(confirmation)
            await wait(model)
            check(store.items.count == 3 && model.sheetError != nil, "cancelled private authentication keeps history and confirmation")
        } else { check(false, "clear confirmation exists") }
        model.dismissSheet()
        model.requestClear()
        if case .confirmation(let confirmation) = model.sheet, let project = registry.workspaces.last {
            try? registry.setActive(project.id)
            model.execute(confirmation)
            await wait(model)
            check(store.items.count == 3 && model.notice?.isError == true, "stale confirmation cannot affect a different workspace")
            try? registry.setActive(originalID)
        }
        model.dismissSheet()
        if let privateItem = seeded.first(where: \.isPrivate) { _ = store.togglePrivate(privateItem) }
        model.requestClear()
        if case .confirmation(let confirmation) = model.sheet {
            model.execute(confirmation)
            await wait(model)
            check(store.items.isEmpty && model.sheet == nil && model.notice?.isError == false,
                  "successful clear updates both history and visible result")
        }

        model.present(.token)
        model.createToken(name: "", scopes: [.searchMeta], days: 30)
        check(tokens.tokens.isEmpty && model.sheetError != nil, "invalid token form creates no authorization")
        model.createToken(name: "测试程序", scopes: [.searchText], days: 30)
        check(tokens.tokens.count == 1 && tokens.tokens[0].allows(.searchMeta)
              && tokens.tokens[0].expiresAt != nil, "token form enforces scope dependency and expiry")
        model.createToken(name: "重复提交", scopes: [.searchMeta], days: 30)
        check(tokens.tokens.count == 1, "duplicate submission cannot create another token")
        model.finishToken()
        check(model.issuedToken != nil && model.preventsDismissal, "one-time secret requires explicit saved acknowledgement")
        if let token = model.issuedToken?.token {
            tokens.recordUse(id: token.id)
            tokens.recordUse(id: token.id)
            tokens.reload()
            check(tokens.tokens.first(where: { $0.id == token.id })?.callCount == 2,
                  "refreshing authorization list keeps unflushed usage statistics")
        }
        model.secretSaved = true
        model.finishToken()
        check(model.issuedToken == nil && model.sheet == nil, "acknowledgement releases the displayed secret")

        do {
            let file = APITokenStore.url(rootDirectory: root)
            let saved = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let before = tokens.tokens
            do {
                _ = try tokens.create(label: "无法保存", scopes: [.searchMeta])
                check(false, "failed token create throws")
            } catch { check(tokens.tokens == before, "failed token create rolls back memory") }
            let confirmation = ManagementConfirmation(title: "撤销", detail: "", button: "", action: .revoke(before[0].id))
            model.present(.confirmation(confirmation))
            model.execute(confirmation)
            await wait(model)
            check(tokens.tokens == before && model.sheetError != nil, "failed revocation keeps token and reports failure")
            tokens.reload()
            check(tokens.loadError != nil, "unreadable token file is not presented as an empty list")
            try FileManager.default.removeItem(at: file)
            try saved.write(to: file)
            tokens.reload()
            model.dismissSheet()
        } catch { check(false, "token failure fixture: \(error)") }

        let board = NSPasteboard.withUniqueName()
        check(SensitiveClipboard.copy("workflow-secret-fixture", to: board, expires: false)
              && board.string(forType: .string) == "workflow-secret-fixture"
              && board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true,
              "explicit secret copy carries the confidential pasteboard marker")
        board.releaseGlobally()

        let noteRows = store.replaceAllForTesting([
            NewClip(kind: .text, text: "note-one", note: "original"),
            NewClip(kind: .text, text: "note-two")
        ])
        let vm = PanelViewModel(store: store, settings: settings)
        if noteRows.count == 2 {
            let first = noteRows[0], second = noteRows[1]
            vm.openNoteEditor(first)
            vm.noteDraft = "unsaved-draft"
            vm.select(second)
            check(store.clip(id: first.id)?.note == "original" && vm.pendingNoteCount == 1,
                  "selection change retains a draft without silently saving it")
            vm.openNoteEditor(first)
            check(vm.noteDraft == "unsaved-draft", "reopening the editor restores its draft")
            vm.requestCloseNoteEditor()
            check(vm.noteDiscardConfirmation && vm.showNoteEditor && vm.noteDraft == "unsaved-draft",
                  "cancel asks before discarding modified text")
            vm.noteDiscardConfirmation = false
            await store.database?.invalidate()
            await vm.saveNoteAsync()
            check(vm.showNoteEditor && vm.noteDraft == "unsaved-draft" && vm.noteError != nil && !vm.noteIsSaving,
                  "failed note save keeps the editor, target and draft")
            let reloaded = await BackgroundStoreLoader.open(directory: root, settings: settings)
            vm.rebind(store: reloaded)
            vm.resumeNoteDraft()
            await vm.saveNoteAsync()
            check(reloaded.clip(id: first.id)?.note == "unsaved-draft" && !vm.showNoteEditor,
                  "retained note can be saved after reconnecting")
            vm.openPreview(reloaded.clip(id: first.id))
            check(vm.previewItem?.id == first.id, "preview opens the requested item")
            vm.previewID = nil
        } else { check(false, "note fixtures exist") }

        do {
            let damagedRoot = root.appendingPathComponent("damaged-registry")
            try FileManager.default.createDirectory(at: damagedRoot, withIntermediateDirectories: true)
            let file = WorkspaceStore.registryURL(in: damagedRoot)
            let original = Data("not valid json".utf8)
            try original.write(to: file)
            let broken = WorkspaceStore(rootDirectory: damagedRoot)
            let retainedBytes = try Data(contentsOf: file)
            check(broken.loadError != nil && retainedBytes == original,
                  "invalid workspace registry remains intact and has a recovery state")
            do {
                _ = try broken.createWorkspace(named: "must not overwrite")
                check(false, "creation with unreadable registry is rejected")
            } catch { check(try Data(contentsOf: file) == original, "recovery state cannot overwrite unreadable registry") }
        } catch { check(false, "registry fixture: \(error)") }

        do {
            let logFile = APIAuditLog.url(rootDirectory: root)
            try Data("invalid audit row\n".utf8).write(to: logFile)
            model.refreshAudit()
            check(model.auditError != nil, "unreadable audit has an error state instead of an empty-history state")
            check(APIAuditLog.clear(rootDirectory: root), "audit recovery clear succeeds")
            model.refreshAudit()
            check(model.auditError == nil && model.audit.isEmpty, "missing audit file is a normal empty state")
        } catch { check(false, "audit error fixture: \(error)") }

        do {
            let file = WorkspaceStore.registryURL(in: root)
            let data = try Data(contentsOf: file)
            let prior = registry.workspaces
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            do {
                try registry.rename(registry.activeID, to: "不能写入的名称")
                check(false, "registry write failure throws")
            } catch { check(registry.workspaces == prior, "failed rename restores registry instead of showing a phantom success") }
            try FileManager.default.removeItem(at: file)
            try data.write(to: file)
        } catch { check(false, "registry rollback fixture: \(error)") }

        print("[WORKFLOW] \(checks - failures)/\(checks) passed")
        return failures == 0 ? 0 : 1
    }
}
