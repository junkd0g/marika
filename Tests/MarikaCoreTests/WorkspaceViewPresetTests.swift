import Foundation
import Testing
@testable import MarikaCore

struct WorkspaceViewPresetTests {
    @Test func changingFocusPreservesBuffersHistoryAndOpenViews() {
        var original = ProjectLayout()
        original.openTab(.stats)
        original.files = [EditorFileState(path: "Draft.swift", draft: "unsaved", baseText: "original")]
        original.selectedFile = "Draft.swift"; original.browserURLs = ["http://localhost:3000"]
        let updated = WorkspaceFocus.design.preset.applying(to: original)
        #expect(updated.panel == .design && updated.secondary == .code)
        #expect(updated.openTabs.contains(.stats) && updated.openTabs.first == .conversation)
        #expect(updated.files == original.files && updated.selectedFile == original.selectedFile)
        #expect(updated.browserURLs == original.browserURLs)
    }
    @Test func savedArrangementsContainNoEditorContentAndRoundTrip() throws {
        var layout = ProjectLayout(); layout.panel = .code; layout.secondary = .browser
        layout.files = [EditorFileState(path: "private.swift", draft: "private text")]
        let preset = WorkspaceViewPreset(name: "Build UI", layout: layout)
        let data = try JSONEncoder().encode(preset)
        #expect(!String(decoding: data, as: UTF8.self).contains("private"))
        #expect(try JSONDecoder().decode(WorkspaceViewPreset.self, from: data) == preset)
        #expect(WorkspaceFocus.debug.preset.stacked)
    }
}
