import Foundation

@main
struct ComposerLocalStateCheck {
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("navigator-composer-local-state-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let first=ComposerLocalState(storageDirectory:root)
        var editor=ComposerEditorState()
        editor.draft="Draft for task one";editor.selectedModel="gpt-test";editor.selectedSkills=["/skill"]
        editor.attachments=[ComposerAttachment(path:"/tmp/reference.png",name:"reference.png",kind:"image")]
        editor.reviewFeedback["review-1"]=ReviewFeedback(ratings:["f1":"Strongly Agree"],notes:["f1":"Useful"],selected:["r1"],clarifications:["r1":"Keep it compact"])
        first.save(editor,for:"task-one")
        first.savePersonalPrompts([QuickPrompt(id:"personal-1",title:"My prompt",length:"Personal",text:"Be concise",isPersonal:true)])
        try first.flush()
        let second=ComposerLocalState(storageDirectory:root)
        let restored=second.editor(for:"task-one")
        precondition(restored.attachments == editor.attachments)
        let legacy=try JSONDecoder().decode(ComposerEditorState.self,from:JSONEncoder().encode(ComposerEditorState()))
        precondition(legacy.attachments == nil)
        precondition(restored.draft == "Draft for task one")
        precondition(restored.reviewFeedback["review-1"]?.selected == ["r1"])
        precondition(second.personalPrompts.first?.title == "My prompt")
        precondition(second.editor(for:"task-two").draft.isEmpty)
        // A replacement archive must win over in-memory state; reload must
        // never write the stale draft back into a restored backup.
        let restoredArchive=ComposerLocalState(storageDirectory:root)
        restoredArchive.save(ComposerEditorState(draft:"Restored draft"),for:"task-one")
        try restoredArchive.flush()
        first.reload()
        precondition(first.editor(for:"task-one").draft == "Restored draft")
        print("Composer local task isolation, flush, restore and recovery passed.")
    }
}
