import AppKit

@MainActor enum ComposerAttachmentCheck {
    static func run(store:ComposerStore)->Bool {
        guard let key=store.state.taskKey else {return false}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("navigator-attachment-check-"+UUID().uuidString,isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        func find(_ view:NSView)->ComposerPromptEditor.TextView? {
            if let editor=view as? ComposerPromptEditor.TextView {return editor}
            return view.subviews.compactMap {find($0)}.first
        }
        guard let window=NSApp.windows.first(where:{$0.isVisible && !$0.isSheet}),let content=window.contentView,let editor=find(content) else {return false}
        let before=store.attachments,text=editor.string
        defer {store.attachments=before}
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let image=root.appendingPathComponent("test image.png"),file=root.appendingPathComponent("report.pdf")
            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            let png=bitmap.representation(using:.png,properties:[:])!
            try png.write(to:image);try Data("fixture".utf8).write(to:file)
            let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()}
            board.writeObjects([image as NSURL,file as NSURL,root as NSURL])
            let info=DragTestInfo(window:window,source:editor,pasteboard:board);info.draggingSourceOperationMask = .copy
            guard editor.draggingEntered(info) == .copy,editor.prepareForDragOperation(info),editor.performDragOperation(info) else {return false}
            guard editor.string == text,store.attachments.count == before.count+3,
                  store.attachments.suffix(3).map(\.kind) == ["image","file","file"],
                  try Data(contentsOf:file) == Data("fixture".utf8),try Data(contentsOf:image) == png else {return false}
            // Native drop and importer share the same path as paste; a raw image
            // must become a durable PNG rather than text or a temporary paste URL.
            board.clearContents();board.setData(png,forType:.png)
            guard editor.receive?(board) == true,let pasted=store.attachments.last,pasted.kind == "image",FileManager.default.fileExists(atPath:pasted.path) else {return false}
            try? FileManager.default.removeItem(atPath:pasted.path)
            board.clearContents();board.writeObjects([URL(string:"https://example.com/reference")! as NSURL])
            guard editor.receive?(board) == true,store.attachments.last?.kind == "url" else {return false}
            board.clearContents();board.setString("ordinary text",forType:.string)
            guard editor.receive?(board) == false else {return false}
            // Duplicate files are not added twice. Switching tasks during an
            // asynchronous import must keep the result in the original draft.
            let incoming=try ComposerAttachmentImport.local(file)
            store.addAttachments([incoming],to:key)
            guard store.attachments.filter({$0.path == file.path}).count == 1 else {return false}
            let localRoot=root.appendingPathComponent("state",isDirectory:true)
            let isolated=ComposerStore(storageDirectory:localRoot)
            var state=ComposerState();state.taskKey="one";isolated.acceptState(state)
            isolated.addAttachments([incoming],to:"one")
            let submission=isolated.captureSubmission()
            isolated.completeSubmission(submission,accepted:false)
            guard isolated.attachments.count == 1 else {return false}
            state.taskKey="two";isolated.acceptState(state)
            let late=try ComposerAttachmentImport.local(image)
            isolated.addAttachments([late],to:"one")
            isolated.completeSubmission(submission,accepted:true)
            guard isolated.attachments.isEmpty else {return false}
            state.taskKey="one";isolated.acceptState(state)
            guard isolated.attachments == [late] else {return false}
            isolated.addAttachments([incoming],to:"one")
            guard isolated.flushLocalState() == nil else {return false}
            let restored=ComposerStore(storageDirectory:localRoot);restored.acceptState(state)
            return restored.attachments == [late,incoming]
        } catch {return false}
    }
}
