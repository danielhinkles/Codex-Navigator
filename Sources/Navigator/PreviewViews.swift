import SwiftUI
import AppKit
import QuickLookThumbnailing
import Quartz
import ImageIO
import UniformTypeIdentifiers

struct WindowDragArea:NSViewRepresentable {
    class DragView:NSView {
        var monitor:Any?
        var down:NSEvent?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
            guard window != nil else {return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { [weak self] event in
                guard let self,let window=self.window,event.window === window else {return event}
                switch event.type {
                case .leftMouseDown:
                    let point=self.convert(event.locationInWindow,from:nil)
                    guard self.bounds.contains(point) else {self.down=nil;return event}
                    // Preserve text selection and native control interactions.
                    var hit=window.contentView?.hitTest(window.contentView?.convert(event.locationInWindow,from:nil) ?? .zero)
                    while let view=hit {
                        if view is NSTextView || view is NSControl {self.down=nil;return event}
                        hit=view.superview
                    }
                    self.down=event
                case .leftMouseDragged:
                    if let down=self.down,hypot(event.locationInWindow.x-down.locationInWindow.x,event.locationInWindow.y-down.locationInWindow.y)>4 {
                        self.down=nil
                        window.performDrag(with:down)
                        return nil
                    }
                case .leftMouseUp:self.down=nil
                default:break
                }
                return event
            }
        }
        deinit {if let monitor {NSEvent.removeMonitor(monitor)}}
        override var mouseDownCanMoveWindow:Bool {true}
        override func mouseDown(with event:NSEvent) {window?.performDrag(with:event)}
    }
    func makeNSView(context:Context) -> DragView {DragView()}
    func updateNSView(_ view:DragView,context:Context) {}
}

struct ProjectIcon:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    let project:Project
    let size:CGFloat
    var overview=false
    var body:some View {
        LogoMark(path:project.logo,style:project.logoStyle,enabled:overview ? project.logoOverview : project.logoFolder,colour:project.colour,size:size)
    }
}
struct LogoMark:View {
    @AppStorage("navigator.previewAccess") private var access=""
    @AppStorage("navigator.textScale") private var textScale=1.0
    let path,style:String
    let enabled:Bool
    let colour:String
    let size:CGFloat
    @StoredState private var loaded:NSImage?
    var body:some View {
        ZStack {
            if enabled, !path.isEmpty,let image=loaded {
                if style == "Folder background" {Image(systemName:"folder.fill").resizable().scaledToFit().foregroundStyle(folderColour(colour))}
                if style == "Button trim" {RoundedRectangle(cornerRadius:size*0.2).fill(folderColour(colour).opacity(0.14));RoundedRectangle(cornerRadius:size*0.2).stroke(folderColour(colour),lineWidth:2)}
                Image(nsImage:image).resizable().scaledToFit().padding(style == "As is" ? 0 : size*0.18)
            } else {Image(systemName:"folder.fill").resizable().scaledToFit().foregroundStyle(folderColour(colour))}
        }.frame(width:size,height:size)
            .task(id:path+String(Double(size))+access) {guard PreviewAccess.enabled else {loaded=nil;return};loaded=await PreparedImages.shared.image(path:path,pixels:max(64,Int(size*2)))}
    }
}
struct LogoEditor:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    @EnvironmentObject var model:NavigatorModel
    @Environment(\.dismiss) private var dismiss
    let project:Project
    @StoredState private var path=""
    @StoredState private var style="As is"
    @StoredState private var overview=true
    @StoredState private var folder=true
    @StoredState private var replacement=false
    @StoredState private var saving=false
    @StoredState private var saveError:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Logo · \(project.name)").font(.title2.bold())
            HStack(spacing:30) {
                VStack {LogoMark(path:path,style:style,enabled:overview,colour:project.colour,size:110);Text("Overview").font(.system(size:12*textScale))}
                VStack {LogoMark(path:path,style:style,enabled:folder,colour:project.colour,size:28);Text(project.name).font(.system(size:12*textScale));Text("Project Folder").font(.system(size:12*textScale)).foregroundStyle(.secondary)}
            }.frame(maxWidth:.infinity,minHeight:160).padding().background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:12)).overlay(alignment:.topLeading) {Text("Preview").font(.system(size:12*textScale)).padding(10)}
            Button("Choose image…") {
                let panel=NSOpenPanel();panel.allowedContentTypes=[.png,.jpeg,.heic,.tiff];panel.canChooseDirectories=false
                if panel.runModal() == .OK,let url=panel.url {path=url.path;replacement=true}
            }
            Picker("Presentation",selection:$style) {ForEach(["As is","Button trim","Folder background"],id:\.self) {Text($0)}}.pickerStyle(.segmented)
            HStack {Toggle("Overview",isOn:$overview);Toggle("Project Folder",isOn:$folder)}.toggleStyle(.checkbox)
            HStack {
                Button("Reset to default") {path="";style="As is";overview=true;folder=true;replacement=false}
                Spacer()
                Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var value:[String:Any] = ["action":"preference","id":project.id,"logoStyle":style,"logoOverview":overview,"logoFolder":folder]
                    if path.isEmpty {value["resetLogo"]=true}
                    if replacement {value["logo"]=path}
                    saving=true;saveError=nil;model.perform(value) {error in saving=false;saveError=error;if error == nil {dismiss()}}
                }.keyboardShortcut(.defaultAction).disabled(saving)
            }
            if let saveError {Text(saveError).foregroundStyle(.red)}
        }.padding(24).frame(width:480)
        .onAppear {path=project.logo;style=project.logoStyle;overview=project.logoOverview;folder=project.logoFolder}
    }
}

struct PathLink:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    let path:String
    var body:some View {
        if !path.isEmpty {
            Link(destination:URL(fileURLWithPath:path)) {Text(path).underline().foregroundStyle(Color.accentColor)}
                .environment(\.openURL,OpenURLAction {url in LinkPolicy.open(url);return .handled})
                .contextMenu {
                    Button("Open") {LinkPolicy.openFile(path)}
                    Button("Reveal in Finder") {NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:path)])}
                    Button("Copy path") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(path,forType:.string)}
                }
        }
    }
}
/// Session text and Codex responses are untrusted. Links from them are limited to web,
/// mail and local file targets, and local files that Launch Services would execute are
/// revealed in Finder instead of opened.
enum LinkPolicy {
    static let webSchemes:Set<String>=["http","https","mailto"]
    static let executableExtensions:Set<String>=["app","command","tool","terminal","sh","zsh","bash","fish","pkg","mpkg","dmg","scpt","scptd","applescript","workflow","action","jar","prefpane","saver","qlgenerator","plugin","bundle","kext","service","webloc","inetloc","fileloc","url","py","rb","pl","php"]
    static func allowed(_ url:URL) -> Bool {
        if url.isFileURL {return true}
        guard let scheme=url.scheme?.lowercased() else {return false}
        return webSchemes.contains(scheme)
    }
    static func isExecutable(_ url:URL) -> Bool {
        if executableExtensions.contains(url.pathExtension.lowercased()) {return true}
        var isDirectory:ObjCBool=false
        guard FileManager.default.fileExists(atPath:url.path,isDirectory:&isDirectory) else {return false}
        if isDirectory.boolValue {return NSWorkspace.shared.isFilePackage(atPath:url.path)}
        // Known document types (images, text, video…) open normally even on volumes that report
        // every file as executable (exFAT/FAT/SMB). Only unknown types fall back to the exec bit.
        if !url.pathExtension.isEmpty,let type=UTType(filenameExtension:url.pathExtension) {
            return type.conforms(to:.executable) || type.conforms(to:.script) || type.conforms(to:.shellScript)
        }
        return FileManager.default.isExecutableFile(atPath:url.path)
    }
    @discardableResult static func open(_ url:URL) -> Bool {
        guard allowed(url) else {return false}
        if url.isFileURL && isExecutable(url) {NSWorkspace.shared.activateFileViewerSelecting([url]);return true}
        return NSWorkspace.shared.open(url)
    }
    @discardableResult static func openFile(_ path:String) -> Bool {open(URL(fileURLWithPath:path))}
}
final class PreparedText:NSObject {
    let value:AttributedString
    init(_ value:AttributedString) {self.value=value}
    static let cache:NSCache<NSString,PreparedText> = {let value=NSCache<NSString,PreparedText>();value.totalCostLimit=8*1024*1024;value.countLimit=256;return value}()
    static let detector=try? NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue)
    static func prepare(_ text:String,allowLocal:Bool) -> AttributedString {
        let key=(allowLocal ? "local:" : "text:")+text
        if let found=cache.object(forKey:key as NSString) {return found.value}
        let value=parse(text,allowLocal:allowLocal)
        cache.setObject(PreparedText(value),forKey:key as NSString,cost:text.utf8.count*4)
        return value
    }
    private static func parse(_ text:String,allowLocal:Bool) -> AttributedString {
        var value=(try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let plain=String(value.characters)
        for match in detector?.matches(in:plain,range:NSRange(plain.startIndex...,in:plain)) ?? [] {
            if let range=Range(match.range,in:plain),let target=Range(range,in:value),value[target].link == nil {value[target].link=match.url}
        }
        // Link bare existing local paths as well as Markdown and web URLs.
        let pathPattern = #"(?:^|[\s(\"])(/(?:Users|Volumes|tmp|private|Applications|Library)/[^\n<>\"]+)"#
        if allowLocal,let regex=try? NSRegularExpression(pattern:pathPattern) {
            for match in regex.matches(in:plain,range:NSRange(plain.startIndex...,in:plain)) {
                guard let rawRange=Range(match.range(at:1),in:plain) else {continue}
                var candidate=String(plain[rawRange]).trimmingCharacters(in:CharacterSet(charactersIn:".,;:) "))
                while !candidate.isEmpty {
                    if FileManager.default.fileExists(atPath:candidate) {
                        let end=plain.index(rawRange.lowerBound,offsetBy:candidate.count)
                        if let range=Range(rawRange.lowerBound..<end,in:value),value[range].link == nil {value[range].link=URL(fileURLWithPath:candidate)}
                        break
                    }
                    guard let lastSpace=candidate.lastIndex(of:" ") else {break}
                    candidate=String(candidate[..<lastSpace]).trimmingCharacters(in:CharacterSet(charactersIn:".,;:) "))
                }
            }
        }
        for run in value.runs {
            if let link=run.link {
                let resolved=(link.scheme == nil && link.path.hasPrefix("/")) ? URL(fileURLWithPath:link.path) : link
                guard LinkPolicy.allowed(resolved) else {value[run.range].link=nil;continue}
                value[run.range].link=resolved
                value[run.range].foregroundColor = .accentColor
                value[run.range].underlineStyle = .single
            }
        }
        return value
    }
}
struct LinkedText:View {
    @AppStorage("navigator.previewAccess") private var access=""
    @AppStorage("navigator.textScale") private var textScale=1.0
    let text:String
    @StoredState private var prepared:AttributedString?
    @StoredState private var links:[URL]=[]
    var body:some View {
        Text(prepared ?? AttributedString(text)).tint(.accentColor).textSelection(.enabled)
            .environment(\.openURL,OpenURLAction {url in LinkPolicy.open(url);return .handled})
            .task(id:text+access) {
                let input=text,allowLocal=PreviewAccess.enabled
                let value=await Task.detached(priority:.userInitiated) {PreparedText.prepare(input,allowLocal:allowLocal)}.value
                guard !Task.isCancelled else {return}
                prepared=value;links=Array(Set(value.runs.compactMap(\.link))).sorted{$0.absoluteString<$1.absoluteString}
            }
            .contextMenu {
                ForEach(links,id:\.self) {url in
                    Menu(url.isFileURL ? url.lastPathComponent : url.absoluteString) {
                        Button("Open") {LinkPolicy.open(url)}
                        if url.isFileURL {Button("Reveal in Finder") {NSWorkspace.shared.activateFileViewerSelecting([url])}}
                        Button("Copy link") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(url.absoluteString,forType:.string)}
                    }
                }
            }
    }
}

actor PreparedImages {
    static let shared=PreparedImages()
    private var values:[String:NSImage]=[:]
    private var order:[String]=[]
    private var costs:[String:Int]=[:]
    func image(path:String,pixels:Int) -> NSImage? {
        guard !path.isEmpty,!Task.isCancelled else {return nil}
        let stamp=(try? FileManager.default.attributesOfItem(atPath:path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key=path+String(stamp)+String(pixels)
        if let image=values[key] {return image}
        guard let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),
            let thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:pixels,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else {return nil}
        let image=NSImage(cgImage:thumbnail,size:.zero)
        values[key]=image;order.append(key);costs[key]=thumbnail.bytesPerRow*thumbnail.height
        while order.count>32 || costs.values.reduce(0,+)>96*1024*1024 {let old=order.removeFirst();values.removeValue(forKey:old);costs.removeValue(forKey:old)}
        return image
    }
}

actor PreparedThumbnails {
    static let shared=PreparedThumbnails()
    private static let cache:NSCache<NSString,NSImage> = {let cache=NSCache<NSString,NSImage>();cache.countLimit=128;cache.totalCostLimit=32*1024*1024;return cache}()
    nonisolated static func cached(_ asset:MediaAsset)->NSImage? {cache.object(forKey:(asset.path+(asset.revision ?? "")) as NSString)}
    private var active=0
    func image(_ asset:MediaAsset) async -> NSImage? {
        let key=(asset.path+(asset.revision ?? "")) as NSString
        if let image=Self.cache.object(forKey:key) {return image}
        while active>=4 {
            do {try await Task.sleep(nanoseconds:20_000_000)} catch {return nil}
        }
        guard !Task.isCancelled else {return nil}
        active+=1;defer {active-=1}
        let request=QLThumbnailGenerator.Request(fileAt:URL(fileURLWithPath:asset.path),size:CGSize(width:200,height:200),scale:2,representationTypes:.thumbnail)
        let result=await withTaskCancellationHandler(operation:{try? await QLThumbnailGenerator.shared.generateBestRepresentation(for:request).nsImage},onCancel:{QLThumbnailGenerator.shared.cancel(request)})
        if let result,!Task.isCancelled {Self.cache.setObject(result,forKey:key,cost:400*400*4)}
        return result
    }
}

struct MediaThumbnail:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    let asset:MediaAsset
    let selected:Bool
    let onSelect:()->Void
    let onPreview:()->Void
    @StoredState private var thumbnail:NSImage?
    @StoredState private var metadata=""
    private var tile:some View {
        VStack(spacing:4) {
            ZStack {
                RoundedRectangle(cornerRadius:6).fill(.quaternary)
                if let image=thumbnail {Image(nsImage:image).resizable().scaledToFit()}
                else {Image(systemName:!asset.available ? "exclamationmark.triangle" : asset.kind == "video" ? "play.circle" : "doc.richtext").foregroundStyle(.secondary)}
            }.frame(height:85).clipShape(RoundedRectangle(cornerRadius:6))
            Text(asset.name).font(.system(size:14*textScale)).lineLimit(2).help(asset.name)
        }
    }
    var body:some View {
        tile.padding(4).background(selected ? Color.accentColor.opacity(0.2) : Color.clear,in:RoundedRectangle(cornerRadius:8))
        .overlay(RoundedRectangle(cornerRadius:8).stroke(selected ? Color.accentColor : .clear,lineWidth:2))
        .contentShape(Rectangle())
        .overlay(MediaClickSurface(probeKey:asset.id,onSelect:onSelect,onPreview:{if asset.available {onPreview()}}))
        .accessibilityAction {onSelect()}
        .accessibilityLabel(asset.name).accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {assetActions}
        .help(hoverText)
        .task(id:asset.path + (asset.revision ?? "") + String(asset.available)) {await loadThumbnail()}
    }
    private var hoverText:String {metadata.isEmpty ? asset.path : asset.name + "\n" + metadata + "\n" + asset.path}
    private var assetActions:some View {
        Group {

            Button("Preview") {onSelect();onPreview()}.disabled(!asset.available)
            Button("Reveal in Finder") {NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:asset.path)])}.disabled(!asset.available)
            Button("Open") {LinkPolicy.openFile(asset.path)}.disabled(!asset.available)
            Button("Copy path") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(asset.path,forType:.string)}
                }
    }
    private func loadThumbnail() async {
        thumbnail=PreviewAccess.enabled ? PreparedThumbnails.cached(asset) : nil;metadata=""
        guard asset.available,PreviewAccess.enabled else {return}
        let path=asset.path,kind=asset.kind
        let info=await Task.detached(priority:.utility) {AssetMetadata.summary(path:path,kind:kind)}.value
        guard !Task.isCancelled else {return}
        metadata=info
        let result=await PreparedThumbnails.shared.image(asset)
        guard !Task.isCancelled else {return}
        thumbnail=result
    }
}

struct AssetPreview:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    let assets:[MediaAsset]
    let initial:MediaAsset
    let columns:Int
    let onSelection:(MediaAsset)->Void
    let onClose:()->Void
    @StoredState private var currentID:String?
        private var asset:MediaAsset {assets.first{$0.id == (currentID ?? initial.id)} ?? initial}
    private var images:[MediaAsset] {assets.filter{$0.available && $0.kind == "image"}}
    private var imageIndex:Int {images.firstIndex{$0.id == asset.id} ?? 0}
    private func adjacentImage(_ offset:Int) {
        guard images.indices.contains(imageIndex+offset) else {return}
        let next=images[imageIndex+offset];currentID=next.id;zoom=1;onSelection(next)
    }
    private func move(_ key:UInt16) {
        let available=assets.filter(\.available)
        guard let position=available.firstIndex(where:{$0.id == asset.id}) else {return}
        var index=GridNavigation.next(index:position,count:available.count,columns:columns,key:key)
        // Preserve the grid geometry even when another media type occupies a cell.
        while index != position && available[index].kind != "image" {
            let next=GridNavigation.next(index:index,count:available.count,columns:columns,key:key)
            if next == index {return};index=next
        }
        guard index != position else {return}
        let next=available[index];currentID=next.id;zoom=1;onSelection(next)
    }
        @StoredState private var zoom=1.0
    @StoredState private var image:NSImage?
    @StoredState private var imageError=false
    @StoredState private var probeID=UUID()
    var body:some View {
        VStack {
            HStack {
                Text(asset.name).font(.headline);Spacer()
                if asset.kind == "image",images.count>1 {
                    Button {adjacentImage(-1)} label:{Image(systemName:"chevron.left")}.disabled(imageIndex==0).help("Previous image")
                    Text("\((images.firstIndex{$0.id == asset.id} ?? 0)+1) of \(images.count)").monospacedDigit()
                    Button {adjacentImage(1)} label:{Image(systemName:"chevron.right")}.disabled(imageIndex==images.count-1).help("Next image")
                }
                if asset.kind == "image" {
                    Text("Zoom")
                    Slider(value:$zoom,in:0.25...6).frame(width:140)
                    Button("Fit") {zoom=1}
                }
                Button("Done") {onClose()}.keyboardShortcut(.cancelAction)
            }.padding()
            if !asset.available {ContentUnavailableView("Asset unavailable",systemImage:"doc.questionmark")}
            else if asset.kind == "image" {
                if let image {ZoomImage(image:image,zoom:$zoom)}
                else if imageError {ContentUnavailableView("Image could not be read",systemImage:"photo.badge.exclamationmark")}
                else {ProgressView("Loading image…")}
            }
            else {NativeAssetPreview(path:asset.path,revision:asset.revision)}
        }.frame(minWidth:500,idealWidth:900,maxWidth:.infinity,minHeight:360,idealHeight:650,maxHeight:.infinity)
        .task(id:asset.path + (asset.revision ?? "")) {
            image=PreparedThumbnails.cached(asset);imageError=false
            guard asset.kind == "image" else {return}
            let loaded=await PreparedImages.shared.image(path:asset.path,pixels:4096)
            guard !Task.isCancelled else {return};image=loaded;imageError=loaded == nil
        }
        .background(PreviewKeyboard {code in
            switch code {
            case 49,53:onClose();return true
            case 123...126:guard asset.kind == "image" else {return false};move(code);return true
            default:return false
            }
        })
        .onAppear {if InteractionProbe.enabled {InteractionProbe.previewID=probeID;InteractionProbe.preview="asset";InteractionProbe.values["previewAdvanced"]={currentID != nil && currentID != initial.id};InteractionProbe.values["previewAtStart"]={(currentID ?? initial.id) == initial.id}}}
        .onDisappear {if InteractionProbe.enabled,InteractionProbe.previewID==probeID {InteractionProbe.preview="";InteractionProbe.previewID=nil}}
    }
}
final class ImageScrollView:NSScrollView {
    override func layout() {
        super.layout()
        let size=NSSize(width:max(1,bounds.width-16),height:max(1,bounds.height-16))
        if documentView?.frame.size != size {documentView?.setFrameSize(size)}
    }
}
struct ZoomImage:NSViewRepresentable {
    let image:NSImage
    @Binding var zoom:Double
    class Coordinator {
        var binding:Binding<Double>
        var observation:NSKeyValueObservation?
        var applying=false
        init(_ binding:Binding<Double>) {self.binding=binding}
    }
    func makeCoordinator() -> Coordinator {Coordinator($zoom)}
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=ImageScrollView();scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true
        scroll.allowsMagnification=true;scroll.minMagnification=0.25;scroll.maxMagnification=6
        let image=NSImageView();image.image=self.image;image.imageScaling = .scaleProportionallyUpOrDown
        image.frame=NSRect(x:0,y:0,width:850,height:600);scroll.documentView=image
        let coordinator=context.coordinator
        coordinator.observation=scroll.observe(\.magnification,options:[.new]) {[weak coordinator] view,_ in
            guard let coordinator,!coordinator.applying else {return}
            let value=view.magnification
            DispatchQueue.main.async {coordinator.binding.wrappedValue=value}
        }
        return scroll
    }
    func updateNSView(_ view:NSScrollView,context:Context) {
        (view.documentView as? NSImageView)?.image=image
        context.coordinator.binding=$zoom
        context.coordinator.applying=true
        if abs(view.magnification-zoom)>0.01 {view.magnification=zoom}
        context.coordinator.applying=false
    }
}
struct NativeAssetPreview:NSViewRepresentable {
    let path:String
    let revision:String?
    final class Coordinator {var key:String?}
    func makeCoordinator()->Coordinator {Coordinator()}
    func makeNSView(context:Context) -> QLPreviewView {QLPreviewView(frame:.zero,style:.normal)!}
    func updateNSView(_ view:QLPreviewView,context:Context) {
        let key=path+"|"+(revision ?? "")
        if context.coordinator.key != key {view.previewItem=URL(fileURLWithPath:path) as NSURL;context.coordinator.key=key}
    }
}

struct PanelDivider:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    @Binding var value:Double
    let limits:ClosedRange<Double>
    var direction=1.0
    var body:some View {
        ResizeHandle(value:$value,limits:limits,vertical:false,direction:direction,label:direction > 0 ? "Projects panel width" : "Preview panel width")
            .frame(width:7)
    }
}

struct VoiceOrganizer:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    @EnvironmentObject var model:NavigatorModel
    @Environment(\.dismiss) private var dismiss
    @StoredState private var targets:[String:String]=[:]
    @StoredState private var saving=false
    @StoredState private var saveError:String?
    private var sessions:[Session] {model.sessions.filter { s in
        s.project == "unassigned" && !s.archived && s.title.lowercased().replacingOccurrences(of:" ",with:"").contains("realtimevoice")
    }.sorted {$0.modified > $1.modified}}
    private func matches(_ s:Session) -> [Project] {
        let words = " " + (s.promptSearchText ?? s.searchText).lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted).filter {!$0.isEmpty}.joined(separator:" ") + " "
        return model.projects.filter {p in
            let name=p.name.lowercased().components(separatedBy:CharacterSet.alphanumerics.inverted).filter {!$0.isEmpty}.joined(separator:" ")
            return name.count >= 5 && words.contains(" " + name + " ")
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Organise voice chats").font(.title2.bold())
            Text("Review project suggestions based on names mentioned in indexed prompts. Assignments are saved in Navigator.").foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    if sessions.isEmpty {Text("No unassigned voice sessions are available in local Codex history.").foregroundStyle(.secondary)}
                    ForEach(sessions) {s in
                        VStack(alignment:.leading,spacing:6) {
                            HStack {Image(systemName:"waveform");Text(s.title).font(.headline);Spacer();Text(dateText(s.modified)).font(.system(size:12*textScale))}
                            Picker("Project",selection:Binding(get:{targets[s.id] ?? ""},set:{targets[s.id]=$0})) {
                                Text("Keep Unassigned").tag("")
                                ForEach(model.projects) {p in Text(p.name).tag(p.id)}
                            }
                            let candidates=matches(s)
                            if candidates.count == 1, let p=candidates.first {
                                Button("Use suggestion: " + p.name) {targets[s.id]=p.id}.font(.system(size:12*textScale))
                            } else {Text(s.indexed ? "Choose a project; no unique name match." : "History is still indexing.").font(.system(size:12*textScale)).foregroundStyle(.secondary)}
                            DisclosureGroup("Read prompts") {LinkedText(text:(s.promptSearchText ?? s.searchText).isEmpty ? "No indexed prompts available." : (s.promptSearchText ?? s.searchText)).font(.system(size:12*textScale))}
                            Divider()
                        }
                    }
                }
            }
            HStack {
                Button("Use all unique suggestions") {for s in sessions {let candidates=matches(s);if candidates.count == 1 {targets[s.id]=candidates[0].id}}}
                Spacer()
                Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Apply assignments") {saving=true;saveError=nil;model.perform(["action":"assignMany","assignments":targets.filter{!$0.value.isEmpty}]) {error in saving=false;saveError=error;if error == nil {dismiss()}}}.disabled(saving || targets.values.allSatisfy {$0.isEmpty})
            }
            if let saveError {Text(saveError).foregroundStyle(.red)}
        }.padding(24).frame(width:700,height:600)
    }
}

struct MediaGallery:View {
    @AppStorage("navigator.previewAccess") private var access=""
    @AppStorage("navigator.textScale") private var textScale=1.0
    let assets:[MediaAsset]
    let indexed:Bool
    var probeKey="asset"
    var reveal:(String)->Void = {_ in}
    @StoredState private var selected:String?
    @StoredState private var gridWidth=0.0
    private var gridColumns:Int {GridNavigation.columns(width:gridWidth,minimum:110*textScale)}
    @StoredState private var galleryFocused=false
    @StoredState private var hovered:String?
    @StoredState private var preview:MediaAsset?
    var body:some View {
        Group {
            if !PreviewAccess.enabled {PreviewAccessNotice(denied:access == "denied")}
            else if assets.contains(where:{$0.unavailableReason == "Access denied"}) {PreviewAccessNotice(denied:true)}
            if assets.isEmpty {Text(indexed ? "No local media references found." : "Media is being indexed…").font(.system(size:12*textScale)).foregroundStyle(.secondary)}
            else {
                Text("\(assets.filter(\.available).count) available · \(assets.filter{!$0.available}.count) unavailable").font(.system(size:12*textScale)).foregroundStyle(.secondary)
                LazyVGrid(columns:[GridItem(.adaptive(minimum:110*textScale))],spacing:8) {
                    ForEach(assets.filter(\.available)) {asset in
                        MediaThumbnail(asset:asset,selected:selected == asset.id,onSelect:{selectAsset(asset)},onPreview:{selected=asset.id;preview=asset})
                            .id(asset.id)
                            .onHover {inside in if inside {hovered=asset.id} else if hovered == asset.id {hovered=nil}}

                    }
                }
                .background(GeometryReader {geometry in
                    Color.clear.onAppear {gridWidth=geometry.size.width}
                        .onChange(of:geometry.size.width) {_,value in gridWidth=value}
                })
                if assets.contains(where:{!$0.available}) {
                    DisclosureGroup("Unavailable references (\(assets.filter{!$0.available}.count))") {
                        VStack(alignment:.leading,spacing:10) {
                            Text("These references remain in the conversation, but their local files cannot be opened.").font(.system(size:12*textScale)).foregroundStyle(.secondary)
                            Button("Copy all unavailable paths") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(assets.filter{!$0.available}.map(\.path).joined(separator:"\n"),forType:.string)
                            }.font(.system(size:12*textScale))
                            ForEach(assets.filter{!$0.available}) {asset in
                                VStack(alignment:.leading,spacing:2) {
                                    Text(asset.name).font(.system(size:12*textScale)).lineLimit(2)
                                    Text(asset.unavailableReason ?? "File missing or inaccessible").font(.system(size:12*textScale)).foregroundStyle(.secondary)
                                }.help(asset.path).contextMenu {
                                    if PreviewAccess.enabled {
                                        Button("Reveal containing folder") {AssetMetadata.revealParent(asset.path)}
                                    }
                                    Button("Copy path") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(asset.path,forType:.string)}
                                }
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(.top,6)
                    }.font(.system(size:12*textScale)).padding(.top,8)
                }
            }
        }.background(KeyboardSurface(active:$galleryFocused,label:"Media gallery") {code in
            switch code {
            case 49:
                guard let asset=assets.first(where:{$0.id==selected && $0.available}) else {return false}
                galleryFocused=false;preview=asset;return true
            case 123...126:moveAsset(code);return true
            default:return false
            }
        })
        .background(PreviewKeyboard {code in
            guard code == 49, preview == nil, let hovered,
                  let asset=assets.first(where:{$0.id == hovered && $0.available}),
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else {return false}
            selected=asset.id;galleryFocused=false;preview=asset;return true
        })
        .sheet(item:$preview,onDismiss:{galleryFocused=true}) {asset in AssetPreview(assets:assets,initial:asset,columns:gridColumns,onSelection:{selected=$0.id},onClose:{preview=nil})}
        .onAppear {registerProbe()}
        .onChange(of:selected) {_,id in if let id {reveal(id)}}
        .onChange(of:assets) {_,values in registerProbe(); if let selected,!values.contains(where:{$0.id==selected && $0.available}) {self.selected=nil;galleryFocused=false;preview=nil}}
    }
    private func selectAsset(_ asset:MediaAsset) {selected=asset.id;galleryFocused=true}
    private func registerProbe() {
        if InteractionProbe.enabled,let asset=assets.first(where:{$0.available}) {
            InteractionProbe.actions[probeKey]={selectAsset(asset)}
            InteractionProbe.values[probeKey+"Focused"]={galleryFocused}
            InteractionProbe.values[probeKey+"Selected"]={selected != nil}
            InteractionProbe.values[probeKey+"Moved"]={selected != nil && selected != asset.id}
            InteractionProbe.values[probeKey+"SelectedVisible"]={InteractionProbe.values["visible-"+(selected ?? "")]?() == true}
            InteractionProbe.values[probeKey+"PreviewRequested"]={preview != nil}
            InteractionProbe.actions[probeKey+"Hover"]={hovered=assets.first(where:{$0.available})?.id}
        }
    }
    private func moveAsset(_ key:UInt16) {
        let values=assets.filter(\.available)
        guard !values.isEmpty else {return}
        let index=values.firstIndex{$0.id==selected} ?? 0
        let id=values[GridNavigation.next(index:index,count:values.count,columns:gridColumns,key:key)].id
        selected=id;galleryFocused=true
    }
}

struct VoiceConversation:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    let messages:[VoiceMessage]
    var body:some View {
        LazyVStack(alignment:.leading,spacing:14) {
            ForEach(messages) {message in
                VStack(alignment:.leading,spacing:6) {
                    Label(message.speaker == "user" ? "You" : message.speaker == "assistant" ? "Assistant" : "Transcript",
                          systemImage:message.speaker == "user" ? "person.crop.circle" : "waveform")
                        .font(.system(size:12*textScale,weight:.semibold)).foregroundStyle(message.speaker == "user" ? Color.accentColor : Color.secondary)
                    LinkedText(text:message.text).frame(maxWidth:.infinity,alignment:.leading)
                }.padding(14).background(message.speaker == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:10))
            }
        }
    }
}

struct SessionPreview:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    let session:Session
    let projectName:String
    let detail:Detail?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("navigator.previewFont") private var fontSize=14.0
    @AppStorage("navigator.previewContrast") private var highContrast=true
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text(session.title).font(.title2.bold());Spacer();Button("Done") {dismiss()}.keyboardShortcut(.cancelAction)}
            Text(projectName).foregroundStyle(.secondary)
            Text("\(session.durationLabel(at:Date())) active · \(dateText(session.modified))")
            HStack {
                Text("Text size")
                Slider(value:$fontSize,in:12...28,step:1).frame(width:150)
                Toggle("Higher contrast",isOn:$highContrast)
            }
            Divider()
            ScrollViewReader {proxy in ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if let messages=detail?.voiceMessages,!messages.isEmpty {
                        Text("Voice conversation").font(.headline)
                        VoiceConversation(messages:messages)
                    } else {
                        Text("First request").font(.headline)
                        LinkedText(text:detail?.prompts.first?.text ?? (detail == nil ? "Loading preview…" : session.indexed ? "No request available." : "History is being indexed…"))
                    }
                    Text(detail?.voiceMessages.isEmpty == false ? "Latest assistant notes" : "Latest response").font(.headline)
                    LinkedText(text:detail?.lastResponse ?? "")
                    MediaGallery(assets:detail?.media ?? [],indexed:session.indexed,probeKey:"nestedAsset",reveal:{proxy.scrollTo($0)})
                }.font(.system(size:fontSize*textScale)).foregroundStyle(highContrast ? Color.primary : Color.secondary)
                    .padding(10).background(highContrast ? Color(nsColor:.textBackgroundColor) : Color.clear)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }}
        }.padding(24).frame(minWidth:500,idealWidth:800,maxWidth:.infinity,minHeight:360,idealHeight:620,maxHeight:.infinity).background(Color(nsColor:.windowBackgroundColor))
    }
}

struct HeightDivider:View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    @Binding var value:Double
    let limits:ClosedRange<Double>
    var body:some View {
        ResizeHandle(value:$value,limits:limits,vertical:true,direction:1,label:"Activity panel height").frame(height:7)
    }
}

struct RenameEditor:View {
    @EnvironmentObject var model:NavigatorModel
    @Environment(\.dismiss) private var dismiss
    let session:Session
    @StoredState private var name=""
    @StoredState private var saving=false
    @StoredState private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Rename in Navigator").font(.title2.bold())
            TextField("Session name",text:$name)
            Text("Codex’s original title is preserved.").foregroundStyle(.secondary)
            if let error {Text(error).foregroundStyle(.red)}
            HStack {
                Spacer();Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save") {
                    saving=true;error=nil
                    model.perform(["action":"preference","id":session.id,"alias":name]) {message in saving=false;error=message;if message == nil {dismiss()}}
                }.disabled(saving).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width:440).onAppear {name=session.title}
    }
}


private enum AssetMetadata {
    static func summary(path:String,kind:String)->String {
        var parts:[String]=[]
        if let values=try? FileManager.default.attributesOfItem(atPath:path),let bytes=values[.size] as? NSNumber {
            parts.append(ByteCountFormatter.string(fromByteCount:bytes.int64Value,countStyle:.file))
        }
        if kind == "image",let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
           let values=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=values[kCGImagePropertyPixelWidth] as? Int,let height=values[kCGImagePropertyPixelHeight] as? Int {
            parts.insert("\(width) × \(height) pixels",at:0)
        }
        return parts.joined(separator:" · ")
    }
    static func revealParent(_ path:String) {
        let url=URL(fileURLWithPath:path).deletingLastPathComponent()
        var directory:ObjCBool=false
        if FileManager.default.fileExists(atPath:url.path,isDirectory:&directory),directory.boolValue {NSWorkspace.shared.selectFile(nil,inFileViewerRootedAtPath:url.path)}
        else {let alert=NSAlert();alert.messageText="Containing folder unavailable";alert.informativeText="The original folder may have been removed or is not accessible.";alert.runModal()}
    }
}
