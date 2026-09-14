import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NavigatorRequestError:LocalizedError {let message:String;var errorDescription:String? {message}}
struct LocalChangeNotice:Identifiable {let id:UUID;let message:String;let undo:()->Void}
struct SearchHit:Decodable,Identifiable,Equatable {
    let threadID,turnID,itemID,role,snippet:String
    let start:Double
    var id:String {threadID+":"+turnID+":"+itemID}
}
struct SearchResponse:Decodable {let query:String;let results:[SearchHit];let incompleteIDs:[String];let complete:Bool;var truncated:Bool?}
struct ConversationItem:Decodable,Identifiable,Equatable {
    let turnID,itemID,role,text:String
    let time:Double
    var id:String {turnID+":"+itemID}
}
struct ConversationPage:Decodable {let id:String;let items:[ConversationItem];let nextCursor:String?;let indexed:Bool;let incomplete:Bool}
struct ConversationTarget:Identifiable {let id:String;let title:String;var itemID:String?;var query:String=""}
struct DiagnosticCheck:Decodable,Identifiable {let id,title,state,detail:String}
struct DiagnosticReport:Decodable {let checks:[DiagnosticCheck];let indexed,total:Int;let connected:Bool}
struct RestoreResponse:Decodable {let uiPreferences:[String:PreferenceValue]?}

/// Only Navigator's own preferences travel in library backups. Data stays typed.
indirect enum PreferenceValue:Codable {
    case string(String),number(Double),bool(Bool),array([PreferenceValue]),object([String:PreferenceValue]),null
    init(from decoder:Decoder)throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil() {self = .null}
        else if let v=try? c.decode(Bool.self) {self = .bool(v)}
        else if let v=try? c.decode(Double.self) {self = .number(v)}
        else if let v=try? c.decode(String.self) {self = .string(v)}
        else if let v=try? c.decode([PreferenceValue].self) {self = .array(v)}
        else {self = .object(try c.decode([String:PreferenceValue].self))}
    }
    func encode(to encoder:Encoder)throws {
        var c=encoder.singleValueContainer()
        switch self {case .string(let v):try c.encode(v);case .number(let v):try c.encode(v);case .bool(let v):try c.encode(v);case .array(let v):try c.encode(v);case .object(let v):try c.encode(v);case .null:try c.encodeNil()}
    }
    var foundation:Any? {
        switch self {
        case .string(let v):return v
        case .number(let v):return v
        case .bool(let v):return v
        case .array(let v):return v.compactMap(\.foundation)
        case .object(let v):
            if case .string(let raw)=v["__navigatorData"],let data=Data(base64Encoded:raw) {return data}
            return v.compactMapValues(\.foundation)
        case .null:return nil
        }
    }
}

enum LibraryPreferences {
    static func export()->[String:Any] {
        NavigatorApp.preferences.dictionaryRepresentation().filter{$0.key.hasPrefix("navigator.") && $0.key != "navigator.previewAccess"}.compactMapValues {value in
            if let data=value as? Data {return ["__navigatorData":data.base64EncodedString()]}
            return JSONSerialization.isValidJSONObject(["value":value]) ? value : nil
        }
    }
    static func restore(_ values:[String:PreferenceValue]) {
        for key in NavigatorApp.preferences.dictionaryRepresentation().keys where key.hasPrefix("navigator.") && key != "navigator.previewAccess" {NavigatorApp.preferences.removeObject(forKey:key)}
        for (key,value) in values where key.hasPrefix("navigator.") && key != "navigator.previewAccess" {
            if let object=value.foundation {NavigatorApp.preferences.set(object,forKey:key)}
        }
    }
}

struct HighlightedSnippet:View {
    let text,query:String
    private var attributed:AttributedString {
        var value=AttributedString(text)
        guard !query.isEmpty else {return value}
        var search=text.startIndex..<text.endIndex
        while let found=text.range(of:query,options:.caseInsensitive,range:search) {
            if let range=Range(found,in:value) {value[range].font = .body.bold();value[range].backgroundColor = .yellow.opacity(0.2)}
            if found.upperBound == text.endIndex {break};search=found.upperBound..<text.endIndex
        }
        return value
    }
    var body:some View {Text(attributed)}
}

struct ConversationReader:View {
    @EnvironmentObject var model:NavigatorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("navigator.textScale") private var textScale=1.0
    let target:ConversationTarget
    @StoredState private var items:[ConversationItem]=[]
    @StoredState private var cursor:String?
    @StoredState private var loading=false
    @StoredState private var incomplete=false
    @StoredState private var error:String?
    @StoredState private var scrollTarget:String?
    @StoredState private var requestGeneration=0
    @StoredState private var atMatch=false
    var body:some View {
        VStack(spacing:0) {
            HStack(alignment:.top,spacing:16) {
                VStack(alignment:.leading,spacing:4) {
                    Text("Conversation").font(.system(size:19*textScale,weight:.semibold))
                    Text(target.title).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Latest") {load(latest:true)}.disabled(loading)
                Button("Open in Codex") {model.open(target.id)}
                Button("Done") {dismiss()}.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollViewReader {proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:16) {
                        if let cursor {
                            Button("Load earlier messages") {load(cursor:cursor)}.disabled(loading).frame(maxWidth:.infinity)
                        }
                        if incomplete {
                            HStack(alignment:.top) {
                                Image(systemName:"clock.arrow.circlepath")
                                Text("Earlier history is still indexing. You can read available messages now.")
                                Spacer(minLength:8)
                                Button("Refresh") {load(latest:!atMatch)}.disabled(loading)
                            }.font(.callout).foregroundStyle(.secondary)
                        }
                        if loading {ProgressView("Loading conversation…").frame(maxWidth:.infinity)}
                        if let error {
                            VStack(alignment:.leading,spacing:8) {Text(error).foregroundStyle(.red);Button("Try again") {load(latest:!atMatch)}}
                        }
                        if !loading && items.isEmpty && error == nil {ContentUnavailableView("No conversation available yet",systemImage:"text.bubble",description:Text("Refresh after the session has been indexed."))}
                        ForEach(items) {item in
                            VStack(alignment:.leading,spacing:8) {
                                HStack {
                                    Label(item.role == "user" ? "You" : "Codex",systemImage:item.role == "user" ? "person.crop.circle" : "sparkle")
                                        .font(.system(size:12*textScale,weight:.semibold)).foregroundStyle(item.role == "user" ? Color.accentColor : .secondary)
                                    Spacer()
                                    if item.time>0 {Text(Date(timeIntervalSince1970:item.time).formatted(date:.abbreviated,time:.shortened)).font(.system(size:11*textScale)).foregroundStyle(.secondary)}
                                    if item.itemID == target.itemID {Text("Search match").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)}
                                }
                                if target.query.isEmpty {LinkedText(text:item.text)}
                                else {HighlightedSnippet(text:item.text,query:target.query).textSelection(.enabled)}
                            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                                .background(item.role == "user" ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
                                .overlay(RoundedRectangle(cornerRadius:10).stroke(item.itemID == target.itemID ? Color.accentColor.opacity(0.5) : .clear))
                                .id(item.id)
                        }
                        Color.clear.frame(height:1).id("latest")
                    }.padding(20)
                }.onChange(of:scrollTarget) {_,id in if let id {DispatchQueue.main.async {proxy.scrollTo(id,anchor:id == "latest" ? .bottom : .top)}}}
            }
        }.font(.system(size:14*textScale)).frame(minWidth:600,idealWidth:860,maxWidth:.infinity,minHeight:500,idealHeight:760,maxHeight:.infinity)
            .background(Color(nsColor:.windowBackgroundColor)).onAppear {load()}
    }
    private func load(cursor:String?=nil,latest:Bool=false) {
        guard !loading else {return};loading=true;error=nil;requestGeneration+=1
        let generation=requestGeneration
        var command:[String:Any] = ["action":"conversation","id":target.id,"limit":40]
        if let cursor {command["cursor"]=cursor}
        else if !latest,let id=target.itemID {command["aroundItemID"]=id;atMatch=true}
        else {atMatch=false}
        model.request(command,as:ConversationPage.self) {result in
            guard generation==requestGeneration else {return};loading=false
            switch result {
            case .failure(let failure):error=failure.localizedDescription
            case .success(let page):
                let oldFirst=items.first?.id
                if cursor != nil {
                    let known=Set(items.map(\.id));items=page.items.filter{!known.contains($0.id)}+items
                    scrollTarget=oldFirst
                } else {
                    items=page.items;scrollTarget=nil
                    DispatchQueue.main.async {scrollTarget=(!latest ? items.first(where:{$0.itemID==target.itemID})?.id : nil) ?? "latest"}
                }
                self.cursor=page.nextCursor;incomplete=page.incomplete
            }
        }
    }
}

struct LibrarySettingsView:View {
    @EnvironmentObject var model:NavigatorModel
    @Environment(\.dismiss) private var dismiss
    @StoredState private var tab="Library"
    @StoredState private var report:DiagnosticReport?
    @StoredState private var busy=false
    @StoredState private var feedback:String?
    @StoredState private var failure:String?
    @StoredState private var confirmRebuild=false
    @StoredState private var restoreURL:URL?
    @StoredState private var confirmRestore=false
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {
                Text("Library & diagnostics").font(.title2.weight(.semibold))
                Spacer();Button("Done") {dismiss()}.keyboardShortcut(.cancelAction).disabled(busy)
            }
            Picker("Section",selection:$tab) {Text("Library").tag("Library");Text("Diagnostics").tag("Diagnostics")}.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment:.leading,spacing:18) {
                    if tab == "Library" {library} else {diagnostics}
                    if busy {ProgressView("Working… Please keep Navigator open.").font(.callout)}
                    if let feedback {Label(feedback,systemImage:"checkmark.circle.fill").foregroundStyle(.green).font(.callout).textSelection(.enabled)}
                    if let failure {Label(failure,systemImage:"exclamationmark.triangle").foregroundStyle(.red).font(.callout).textSelection(.enabled)}
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(24).frame(width:610,height:570).background(Color(nsColor:.windowBackgroundColor))
        .interactiveDismissDisabled(busy)
        .onAppear {if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--diagnostics-preview") {tab="Diagnostics";check()}}
        .onChange(of:tab) {_,value in if value == "Diagnostics" {check()}}
        .confirmationDialog("Rebuild the history index?",isPresented:$confirmRebuild,titleVisibility:.visible) {
            Button("Rebuild history index") {perform("rebuildIndex",success:"History index rebuilt. Your organisation and working files are preserved.")}
        } message: {Text("Navigator will read your local Codex history again. Assignments, favourites, logos, drafts and working folders are preserved.")}
        .confirmationDialog("Restore this Navigator backup?",isPresented:$confirmRestore,titleVisibility:.visible) {
            Button("Restore backup") {restore()}
        } message: {Text("Your Navigator library and settings will be restored from the selected backup. Codex projects and source history are not changed. Finish active Composer tasks first.")}
    }
    private var library:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Keep your local library safe").font(.headline)
            Text("Your organisation, drafts and working files belong to you. Back up before making recovery changes.").foregroundStyle(.secondary)
            actionRow("Back up Navigator data",detail:"Save a portable copy of this library and local settings.",icon:"externaldrive.badge.plus") {backup()}
            actionRow("Restore a backup",detail:"Validate a saved backup before restoring the library.",icon:"arrow.counterclockwise") {chooseRestore()}
            Divider()
            actionRow("Rebuild history index",detail:"Read Codex history again while keeping your local organisation, drafts and working folders.",icon:"arrow.triangle.2.circlepath") {confirmRebuild=true}
            if model.hasActiveComposer {Label("Finish or stop active Composer tasks before backing up, restoring or rebuilding.",systemImage:"info.circle").font(.callout).foregroundStyle(.secondary)}
        }
    }
    private var diagnostics:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {Text("Connection & local setup").font(.headline);Spacer();Button("Check again") {check()}.disabled(busy)}
            diagnosticRow(title:"Python runtime",state:FileManager.default.isExecutableFile(atPath:"/usr/bin/python3") ? "ok" : "error",detail:"Navigator uses the Python runtime supplied with Apple's command-line tools.")
            diagnosticRow(title:"Index worker",state:model.workerRunning ? "ok" : "error",detail:model.workerRunning ? "The local worker is running." : "The local worker could not start or has stopped.")
            if let report {
                ForEach(report.checks) {item in diagnosticRow(title:item.title,state:item.state,detail:item.detail)}
            }
            HStack {
                Button("Reconnect index") {model.reconnectIndex();DispatchQueue.main.asyncAfter(deadline:.now()+1) {check()}}.disabled(busy)
                Spacer()
                Button("Copy diagnostic report") {copyReport()}
            }
            Text("The copied report excludes conversation text, credentials and personal file paths.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func actionRow(_ title:String,detail:String,icon:String,action:@escaping()->Void)->some View {
        HStack(alignment:.top,spacing:14) {
            Image(systemName:icon).font(.title3).foregroundStyle(Color.accentColor).frame(width:28)
            VStack(alignment:.leading,spacing:5) {Button(title,action:action).buttonStyle(.link);Text(detail).font(.callout).foregroundStyle(.secondary)}
            Spacer(minLength:0)
        }.disabled(busy).padding(.vertical,4)
    }
    private func diagnosticRow(title:String,state:String,detail:String)->some View {
        HStack(alignment:.top,spacing:10) {
            Image(systemName:state == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(state == "ok" ? Color.green : state == "error" ? .red : .orange)
            VStack(alignment:.leading,spacing:3) {Text(title).fontWeight(.medium);Text(detail).font(.callout).foregroundStyle(.secondary)}
        }
    }
    private func check() {
        guard !busy else {return};failure=nil
        model.request(["action":"diagnostics"],as:DiagnosticReport.self) {result in switch result {case .success(let value):report=value;case .failure(let error):failure=error.localizedDescription}}
    }
    private func backup() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.zip];panel.nameFieldStringValue="Navigator Backup " + Date().formatted(.iso8601.year().month().day()) + ".zip"
        panel.begin {response in guard response == .OK,let url=panel.url else {return};perform("backup",extra:["path":url.path,"uiPreferences":LibraryPreferences.export()],success:"Backup saved successfully.")}
    }
    private func chooseRestore() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.zip];panel.canChooseDirectories=false
        panel.begin {response in guard response == .OK,let url=panel.url else {return};restoreURL=url;confirmRestore=true}
    }
    private func perform(_ action:String,extra:[String:Any]=[:],success:String) {
        busy=true;model.libraryBusy=true;feedback=nil;failure=nil
        if let error=model.composerStore.flushLocalState() {busy=false;model.libraryBusy=false;failure=error;return}
        var command=extra;command["action"]=action
        model.perform(command,undoManager:nil) {error in busy=false;model.libraryBusy=false;if let error {failure=error} else {feedback=success}}
    }
    private func restore() {
        guard let restoreURL else {return};busy=true;model.libraryBusy=true;feedback=nil;failure=nil
        if let error=model.composerStore.flushLocalState() {busy=false;model.libraryBusy=false;failure=error;return}
        model.request(["action":"restoreBackup","path":restoreURL.path],as:RestoreResponse.self) {result in
            busy=false;model.libraryBusy=false
            switch result {
            case .success(let value):
                if let prefs=value.uiPreferences {LibraryPreferences.restore(prefs)}
                NotificationCenter.default.post(name:Notification.Name("NavigatorLibraryRestored"),object:nil)
                model.composerStore.reloadLocalState()
                model.localNotice=nil;NSApp.keyWindow?.undoManager?.removeAllActions()
                feedback="Backup restored. Your library is ready.";model.send(["action":"refresh"])
            case .failure(let error):failure=error.localizedDescription
            }
        }
    }
    private func copyReport() {
        var lines=["Codex Navigator diagnostics", "Python runtime: " + (FileManager.default.isExecutableFile(atPath:"/usr/bin/python3") ? "available" : "unavailable"),"Index worker: " + (model.workerRunning ? "running" : "unavailable")]
        if let report {lines += report.checks.map{$0.title+": "+$0.state+" — "+$0.detail};lines.append("Indexed: \(report.indexed)/\(report.total)")}
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(lines.joined(separator:"\n"),forType:.string)
    }
}
