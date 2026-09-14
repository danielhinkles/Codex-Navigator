import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

enum ComposerAttachmentImport {
    static var directory:URL {ComposerLocalState.defaultDirectory().appendingPathComponent("attachments",isDirectory:true)}
    static func local(_ url:URL) throws -> ComposerAttachment {
        let url=url.standardizedFileURL
        let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()}}
        let values=try url.resourceValues(forKeys:[.isDirectoryKey,.contentTypeKey,.isReadableKey])
        guard values.isReadable != false else {throw CocoaError(.fileReadNoPermission)}
        if values.isDirectory != true,values.contentType?.conforms(to:.image) == true,
           let source=CGImageSourceCreateWithURL(url as CFURL,nil),CGImageSourceGetCount(source)>0 {
            // Convert less portable image formats; never change the source file.
            if ["png","jpg","jpeg","webp","gif"].contains(url.pathExtension.lowercased()) {
                return ComposerAttachment(path:url.path,name:url.lastPathComponent,kind:"image")
            }
            guard let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw CocoaError(.fileReadCorruptFile)}
            let converted=try savePNG(image)
            return ComposerAttachment(path:converted.path,name:url.lastPathComponent,kind:"image")
        }
        return ComposerAttachment(path:url.path,name:url.lastPathComponent,kind:"file")
    }
    static func savePNG(_ image:CGImage) throws -> URL {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url=directory.appendingPathComponent(UUID().uuidString+".png")
        guard let target=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {throw CocoaError(.fileWriteUnknown)}
        CGImageDestinationAddImage(target,image,nil)
        guard CGImageDestinationFinalize(target) else {throw CocoaError(.fileWriteUnknown)}
        return url
    }
    static func rawImage(_ data:Data) throws -> ComposerAttachment {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw CocoaError(.fileReadCorruptFile)}
        return ComposerAttachment(path:try savePNG(image).path,name:"Pasted image.png",kind:"image")
    }
    static let types:[NSPasteboard.PasteboardType] = [.fileURL,.URL,.png,.tiff] + NSFilePromiseReceiver.readableDraggedTypes.map {NSPasteboard.PasteboardType($0)}
    static func supports(_ board:NSPasteboard)->Bool {board.availableType(from:types) != nil}
    /// Capture the destination task before asynchronous file promises complete.
    static func receive(_ board:NSPasteboard,completion:@escaping ([ComposerAttachment],String?)->Void)->Bool {
        guard supports(board) else {return false}
        if let urls=board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty {
            var attachments:[ComposerAttachment]=[];var errors:[String]=[]
            for url in urls {do {attachments.append(try local(url))} catch {errors.append(url.lastPathComponent+": "+error.localizedDescription)}}
            completion(attachments,errors.isEmpty ? nil : errors.joined(separator:"\n"));return true
        }
        if let promises=board.readObjects(forClasses:[NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],!promises.isEmpty {
            do {try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)} catch {completion([],error.localizedDescription);return true}
            let queue=OperationQueue();queue.maxConcurrentOperationCount=1
            for promise in promises {
                let destination=directory.appendingPathComponent(UUID().uuidString,isDirectory:true)
                do {try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)} catch {completion([],error.localizedDescription);continue}
                promise.receivePromisedFiles(atDestination:destination,options:[:],operationQueue:queue) {url,error in
                    let result:Result<ComposerAttachment,Error> = error.map { .failure($0) } ?? Result {try local(url)}
                    DispatchQueue.main.async {switch result {case .success(let attachment):completion([attachment],nil);case .failure(let error):completion([],error.localizedDescription)}}
                }
            }
            return true
        }
        for type in [NSPasteboard.PasteboardType.png,.tiff] {
            if let data=board.data(forType:type) {do {completion([try rawImage(data)],nil)} catch {completion([],error.localizedDescription)};return true}
        }
        if let urls=board.readObjects(forClasses:[NSURL.self]) as? [URL],!urls.isEmpty {
            let supported=urls.filter {["http","https"].contains($0.scheme?.lowercased() ?? "")}
            completion(supported.map {ComposerAttachment(path:$0.absoluteString,name:$0.lastPathComponent.isEmpty ? ($0.host ?? $0.absoluteString) : $0.lastPathComponent,kind:["png","jpg","jpeg","webp","gif"].contains($0.pathExtension.lowercased()) ? "remoteImage" : "url")},supported.count == urls.count ? nil : "Only web links and local files can be attached.")
            return true
        }
        completion([],"This drag did not provide a readable file, image, or web link.");return true
    }
}

/// Own the native text destination so NSTextView cannot insert file paths first.
struct ComposerPromptEditor:NSViewRepresentable {
    @Binding var text:String
    var fontSize:Double
    var enabled:Bool
    var taskKey:String
    var onAttachments:(String,[ComposerAttachment],String?)->Void
    final class TextView:NSTextView {
        var receive:((NSPasteboard)->Bool)?
        var editorTaskKey=""
        private let editorUndo=UndoManager()
        override var undoManager:UndoManager? {editorUndo}
        override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {
            if ComposerAttachmentImport.supports(sender.draggingPasteboard) {return isEditable ? .copy : []}
            return super.draggingEntered(sender)
        }
        override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation {draggingEntered(sender)}
        override func prepareForDragOperation(_ sender:NSDraggingInfo)->Bool {isEditable}
        override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
            if ComposerAttachmentImport.supports(sender.draggingPasteboard) {return isEditable && receive?(sender.draggingPasteboard) == true}
            return super.performDragOperation(sender)
        }
        override func paste(_ sender:Any?) {
            if isEditable,receive?(.general) == true {return}
            super.paste(sender)
        }
    }
    final class ScrollView:NSScrollView {
        override func layout() {
            super.layout()
            if let view=documentView as? NSTextView {
                view.minSize=NSSize(width:0,height:contentSize.height)
                view.setFrameSize(NSSize(width:contentSize.width,height:max(contentSize.height,view.frame.height)))
            }
        }
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:ComposerPromptEditor
        init(_ parent:ComposerPromptEditor) {self.parent=parent}
        func textDidChange(_ notification:Notification) {if let view=notification.object as? NSTextView {parent.text=view.string}}
    }
    func makeCoordinator()->Coordinator {Coordinator(self)}
    func makeNSView(context:Context)->NSScrollView {
        let scroll=ScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false
        let view=TextView();view.isRichText=false;view.allowsUndo=true;view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false
        view.drawsBackground=false;view.textContainerInset=NSSize(width:8,height:8)
        view.isVerticallyResizable=true;view.isHorizontallyResizable=false;view.autoresizingMask=[.width]
        view.textContainer?.widthTracksTextView=true;view.textContainer?.containerSize=NSSize(width:0,height:CGFloat.greatestFiniteMagnitude)
        view.delegate=context.coordinator;view.registerForDraggedTypes(ComposerAttachmentImport.types)
        view.setAccessibilityLabel("Prompt for Codex");scroll.documentView=view
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        context.coordinator.parent=self
        guard let view=scroll.documentView as? TextView else {return}
        if view.editorTaskKey != taskKey || view.string != text {
            view.undoManager?.removeAllActions();view.editorTaskKey=taskKey
            view.string=text
        }
        view.font = .systemFont(ofSize:fontSize);view.textColor = .labelColor;view.isEditable=enabled
        let key=taskKey,callback=onAttachments
        view.receive={board in ComposerAttachmentImport.receive(board) {attachments,error in callback(key,attachments,error)}}
    }
}

struct ComposerAttachmentTile:View {
    let attachment:ComposerAttachment
    let remove:(()->Void)?
    @StoredState private var thumbnail:NSImage?
    @StoredState private var preview:URL?
    var body:some View {
        HStack(spacing:8) {
            Button {
                if ["url","remoteImage"].contains(attachment.kind) {
                    if let url=URL(string:attachment.path),["http","https"].contains(url.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(url)}
                }
                else {preview=URL(fileURLWithPath:attachment.path)}
            } label: {
                HStack {
                    if attachment.kind == "remoteImage" {
                        AsyncImage(url:URL(string:attachment.path)) {image in image.resizable().scaledToFit()} placeholder: {Image(systemName:"photo")}.frame(width:64,height:52)
                    } else if let thumbnail {Image(nsImage:thumbnail).resizable().scaledToFit().frame(width:64,height:52)}
                    else {Image(systemName:attachment.kind == "url" ? "link" : "doc").frame(width:32,height:40)}
                    Text(attachment.name).lineLimit(2).frame(maxWidth:140,alignment:.leading)
                }
            }.buttonStyle(.plain).help(attachment.path)
            if let remove {Button(action:remove) {Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).help("Remove attachment")}
        }.padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
        .sheet(isPresented:Binding(get:{preview != nil},set:{if !$0 {preview=nil}})) {
            VStack {
                HStack {Text(attachment.name).font(.headline);Spacer();Button("Close") {preview=nil}.keyboardShortcut(.cancelAction)}
                NativeAssetPreview(path:attachment.path,revision:nil)
            }.padding(16).frame(minWidth:600,minHeight:440)
                .background(PreviewKeyboard {code in if code == 49 || code == 53 {preview=nil;return true};return false})
        }
        .task(id:attachment.path) {
            guard !["url","remoteImage"].contains(attachment.kind) else {return}
            let path=attachment.path
            thumbnail=await Task.detached(priority:.utility) {
                if let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),
                   let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:160,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) {return NSImage(cgImage:image,size:.zero)}
                return NSWorkspace.shared.icon(forFile:path)
            }.value
        }
    }
}
