import AppKit
import SwiftUI

struct Session: Equatable, Decodable, Identifiable {
    let id, title, project, nativeProject, sync, cwd: String
    let created, modified, seconds, activeStart: Double
    var status: String
    let runtimeCoverage: String
    let indexed: Bool
    let indexError: String
    let size, mediaCount, promptCount, messages, filesChanged: Int
    let archived, favourite: Bool
    let sessionType, searchText: String
    var promptSearchText:String?
    let tokenUsage: Int?
    let source, model: String
    let lastChecked: Double
    var running: Bool { status == "Running" }
    func duration(at date: Date) -> Double { seconds + (running && activeStart > 0 ? max(0, date.timeIntervalSince1970 - activeStart) : 0) }
    func durationLabel(at date: Date) -> String { runtimeCoverage == "unavailable" ? "—" : (runtimeCoverage == "partial" ? "≥ " : "") + durationText(duration(at:date)) }
}
struct Project: Equatable, Decodable, Identifiable {
    let id, name, path, colour, logo, logoStyle, group, sessionType: String
    let logoOverview, logoFolder, pinned, codexPinned: Bool
}
struct Prompt: Equatable, Decodable, Identifiable { let id, text: String; let time: Double }
struct MediaAsset: Equatable, Decodable, Identifiable { let id, path, name, kind: String; let available: Bool; var unavailableReason: String? = nil; var revision:String? = nil }
struct Activity: Equatable, Decodable { let start, end, seconds: Double }
struct VoiceMessage: Equatable, Decodable, Identifiable { let id, speaker, text: String }
struct Detail: Equatable, Decodable { let id: String; let prompts: [Prompt]; let media: [MediaAsset]; let lastResponse: String; let voiceMessages: [VoiceMessage]; let activity: [Activity] }
struct Snapshot: Decodable {
    let sessions: [Session]; let projects: [Project]; let connected: Bool; let message: String
    let activity: [String: [Activity]]
}

struct Envelope:Decodable {let type:String; var message:String?; var connected:Bool?; var url:String?; var id:String?; var requestID:String?}
struct Delta:Decodable {let sessions:[Session];let removed:[String];let projects:[Project]?;let activity:[String:[Activity]]}
struct ProjectStats {var modified=0.0;var size=0;var running=false}

final class NavigatorModel: ObservableObject {
    let composerStore=ComposerStore()
    let composerAudio=ComposerAudio()
    var composer:ComposerState {get {composerStore.state} set {composerStore.acceptState(newValue);composerAudio.accept(newValue)}}
    var composerDraft:String {get {composerStore.draft} set {composerStore.draft=newValue}}
    var composerSubmitting:Bool {get {composerStore.submitting} set {composerStore.submitting=newValue}}
    @Published var sessions: [Session] = []
    @Published var projects: [Project] = []
    @Published var details: [String: Detail] = [:]
    @Published var activity: [String: [Activity]] = [:]
    @Published var connected = false
    @Published var message = "Starting local index…"
    @Published var error: String?
    @Published var revision=0
    @Published var detailErrors:[String:String]=[:]
    @Published var localNotice:LocalChangeNotice?
    @Published var libraryBusy=false {didSet {AppDelegate.maintenanceInProgress=libraryBusy}}
    private var queries:[String:(Result<Data,Error>)->Void]=[:]
    var workerRunning:Bool {process?.isRunning == true}
    var hasActiveComposer:Bool {composer.active || (composer.tasks ?? []).contains { ["starting","reconnecting","running","approval","stopping"].contains($0.status) }}
    private(set) var projectStats:[String:ProjectStats]=[:]
    private(set) var projectNames:[String:String]=[:]
    private var windowWatches:[String:Set<String>]=[:]
    private var detailOrder:[String]=[]
    private var pending:[String:(UndoManager?,[String:Any],(String?)->Void)]=[:]
    private let writeQueue=DispatchQueue(label:"navigator.write")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "navigator.ipc")
    private var stopping = false
    private var restartAttempts = 0
    private var watchedIDs: Set<String> = []

    init() { start() }

    func start() {
        guard !stopping else { return }
        output?.readabilityHandler = nil
        queue.async { self.buffer.removeAll() }
        let resource = Bundle.main.resourceURL?.appendingPathComponent("backend/worker.py")
        let script = resource.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? Bundle.developmentScript("worker.py")
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var args = [script.path]
        if CommandLine.arguments.contains("--demo") {
            args += ["--demo", "--cache", FileManager.default.temporaryDirectory.appendingPathComponent("navigator-demo-\(ProcessInfo.processInfo.processIdentifier)").path]
        } else if let cache = ProcessInfo.processInfo.environment["NAVIGATOR_CACHE"] {
            args += ["--cache", cache]
        }
        if !PreviewAccess.enabled {args.append("--defer-media-access")}
        p.arguments = args
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.standardError
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.receive(data) }
        }
        p.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self = self, self.process === ended, !self.stopping else { return }
                self.connected = false
                self.failPending()
                self.composer.active=false;self.composer.status="disconnected";self.composer.error="Navigator disconnected. Reconnect to check the task before sending again."
                self.sessions = self.sessions.map { session in
                    var value = session
                    if value.running { value.status = "Status stale" }
                    return value
                }
                self.rebuildDerived()
                self.restartAttempts += 1
                let delay = min(30, 2 * self.restartAttempts)
                self.message = "Index worker stopped · keeping history · reconnecting in \(delay)s"
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) { [weak self] in
                    guard let self = self, self.process === ended, !self.stopping else { return }
                    self.start()
                }
            }
        }
        do { try p.run(); process = p; for (window,ids) in windowWatches {send(["action":"watch","window":window,"ids":Array(ids)])} }
        catch {
            input=nil;output=nil;process=nil;connected=false
            self.error = "Could not start the local index: \(error.localizedDescription)"
            message="Local index could not start. Open Library & diagnostics to check setup."
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            do {
                let envelope = try JSONDecoder().decode(Envelope.self,from:line)
                switch envelope.type {
                case "composerVoiceAudio":
                    let packet=try JSONDecoder().decode(ComposerVoicePacket.self,from:line)
                    DispatchQueue.main.async {self.composerAudio.receive(packet)}
                case "composer":
                    let value=try JSONDecoder().decode(ComposerState.self,from:line)
                    DispatchQueue.main.async {self.composer=value}

                case "snapshot":
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: line)
                    DispatchQueue.main.async {
                        self.sessions = snapshot.sessions; self.projects = snapshot.projects
                        self.connected = snapshot.connected; self.message = snapshot.message
                        if snapshot.connected {self.restartAttempts=0}
                        self.activity = snapshot.activity; self.rebuildDerived()
                    }
                case "delta":
                    let delta=try JSONDecoder().decode(Delta.self,from:line)
                    DispatchQueue.main.async {
                        var map=Dictionary(self.sessions.map{($0.id,$0)},uniquingKeysWith:{_,new in new})
                        for id in delta.removed {map.removeValue(forKey:id);self.activity.removeValue(forKey:id);self.details.removeValue(forKey:id)}
                        for session in delta.sessions {map[session.id]=session}
                        if !delta.sessions.isEmpty || !delta.removed.isEmpty {self.sessions=map.values.sorted{$0.id<$1.id}}
                        if let projects=delta.projects {self.projects=projects}
                        for (id,items) in delta.activity {self.activity[id]=items}
                        self.rebuildDerived()
                    }
                case "detail":
                    let detail = try JSONDecoder().decode(Detail.self, from: line)
                    DispatchQueue.main.async {
                        self.detailErrors.removeValue(forKey:detail.id)
                        if self.details[detail.id] != detail {self.details[detail.id] = detail}
                        self.detailOrder.removeAll{$0==detail.id};self.detailOrder.append(detail.id);self.trimDetails()
                    }
                case "status":
                    DispatchQueue.main.async {
                        self.message = envelope.message ?? "Index reconnecting…"
                        self.connected = envelope.connected ?? false
                        if self.connected {self.restartAttempts=0}
                    }
                case "detailError":
                    DispatchQueue.main.async {if let id=envelope.id {self.detailErrors[id]=envelope.message}}
                case "ack":
                    let object = try JSONSerialization.jsonObject(with:line) as? [String:Any]
                    let undo=object?["undo"] as? [String:Any]
                    DispatchQueue.main.async { [self] in
                        guard let id=envelope.requestID, let (manager,original,completion)=self.pending.removeValue(forKey:id) else {return}
                        if let undo,let manager {
                            manager.registerUndo(withTarget:self) {target in target.applyUndo(undo,opposite:original,manager:manager)}
                            let title=self.changeTitle(original)
                            manager.setActionName(title)
                            let token=UUID()
                            self.localNotice=LocalChangeNotice(id:token,message:title + " in Navigator",undo:{ [weak self, weak manager] in
                                guard let self,let manager,self.localNotice?.id == token,manager.canUndo,manager.undoActionName == title else {return}
                                self.localNotice=nil;manager.undo()
                            })
                            DispatchQueue.main.asyncAfter(deadline:.now()+8) { [weak self] in if self?.localNotice?.id == token {self?.localNotice=nil} }
                        }
                        completion(nil)
                    }
                case "error":
                    DispatchQueue.main.async {
                        if let id=envelope.requestID,let completion=self.queries.removeValue(forKey:id) {completion(.failure(NavigatorRequestError(message:envelope.message ?? "Request failed")))}
                        else if let id=envelope.requestID,let (_,_,completion)=self.pending.removeValue(forKey:id) {completion(envelope.message ?? "Unable to save")}
                        else {self.error=envelope.message}
                    }
                case "openURL":
                    if let value=envelope.url,let url=URL(string:value),url.scheme=="codex" {
                        DispatchQueue.main.async {if !NSWorkspace.shared.open(url) {self.error="Codex could not open the new session composer."}}
                    }
                case "open":
                    if let id=envelope.id {DispatchQueue.main.async {self.open(id)}}
                case "maintenancePending":break
                default:
                    if let id=envelope.requestID {
                        let payload=Data(line)
                        DispatchQueue.main.async {self.queries.removeValue(forKey:id)?(.success(payload))}
                    }
                }
            } catch {
                DispatchQueue.main.async { self.error = "Unable to read an index update: \(error.localizedDescription)" }
            }
        }
    }

    private func rebuildDerived() {
        projectNames=Dictionary(projects.map{($0.id,$0.name)},uniquingKeysWith:{_,new in new})
        var stats:[String:ProjectStats]=[:]
        for session in sessions {
            var value=stats[session.project] ?? ProjectStats()
            value.modified=max(value.modified,session.modified);value.size+=session.size;value.running = value.running || session.running
            stats[session.project]=value
        }
        projectStats=stats;revision+=1
    }
    private func trimDetails() {
        while details.count>32,let id=detailOrder.first(where:{!watchedIDs.contains($0)}) {
            details.removeValue(forKey:id);detailErrors.removeValue(forKey:id);detailOrder.removeAll{$0==id}
        }
    }
    func send(_ object:[String:Any]) {
        if let action=object["action"] as? String,["assign","assignMany","favouriteMany","preference","groupProjects","restore","restoreLocal"].contains(action),object["requestID"] == nil {
            perform(object);return
        }
        guard let data=try? JSONSerialization.data(withJSONObject:object),let handle=input else {return}
        writeQueue.async {
            do {try handle.write(contentsOf:data+Data([10]))}
            catch {DispatchQueue.main.async {self.error="The local index is disconnected.";self.failPending()}}
        }
    }
    func perform(_ object:[String:Any],undoManager:UndoManager?=NSApp.keyWindow?.undoManager,completion:((String?)->Void)?=nil) {
        let id=UUID().uuidString
        pending[id]=(undoManager,object,completion ?? {if let message=$0 {self.error=message}})
        guard process?.isRunning == true else {failPending();return}
        var command=object;command["requestID"]=id;send(command)
    }
    private func applyUndo(_ command:[String:Any],opposite:[String:Any],manager:UndoManager) {
        manager.registerUndo(withTarget:self) {target in target.applyUndo(opposite,opposite:command,manager:manager)}
        manager.setActionName("Navigator change")
        perform(command,undoManager:nil)
    }
    private func failPending() {
        let requests=Array(queries.values);queries.removeAll()
        for completion in requests {completion(.failure(NavigatorRequestError(message:"The local index disconnected. Try again after reconnecting.")))}
        let callbacks=Array(pending.values);pending.removeAll()
        for (_,_,completion) in callbacks {completion("The index disconnected. Your changes were not confirmed; try again.")}
    }
    func submitComposer() {
        guard !(composer.taskKey ?? "").isEmpty,!composerSubmitting,!composer.active,composer.status != "disconnected" else {return}
        let submission=composerStore.captureSubmission()
        guard !submission.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !submission.attachments.isEmpty else {return}
        composerSubmitting=true
        perform(["action":"composerSend","taskKey":submission.taskKey,"text":submission.text,"model":submission.model,"effort":submission.effort,"skills":submission.skills,"attachments":submission.attachments.map(\.payload)],undoManager:nil) {error in
            self.composerStore.completeSubmission(submission,accepted:error == nil)
            if let error {self.error=error}
        }
    }
    func request<T:Decodable>(_ object:[String:Any],as type:T.Type,completion:@escaping(Result<T,Error>)->Void) {
        guard workerRunning else {completion(.failure(NavigatorRequestError(message:"The local index is unavailable. Use Reconnect index in Library & diagnostics.")));return}
        let id=UUID().uuidString
        queries[id]={result in completion(result.flatMap {data in Result {try JSONDecoder().decode(T.self,from:data)}})}
        var command=object;command["requestID"]=id;send(command)
        DispatchQueue.main.asyncAfter(deadline:.now()+120) { [weak self] in
            self?.queries.removeValue(forKey:id)?(.failure(NavigatorRequestError(message:"This request has not completed. Check the index status before trying again.")))
        }
    }
    func reconnectIndex() {
        if workerRunning {send(["action":"refresh"])} else {restartAttempts=0;start()}
    }
    private func changeTitle(_ command:[String:Any])->String {
        let count=(command["assignments"] as? [String:String])?.count ?? (command["ids"] as? [String])?.count ?? 1
        switch command["action"] as? String {
        case "assign","assignMany":return countText(count,"session") + " assigned"
        case "favouriteMany":return countText(count,"session") + ((command["favourite"] as? Bool) == true ? " favourited" : " removed from favourites")
        case "groupProjects":return countText(count,"project") + ((command["name"] as? String)?.isEmpty == true ? " ungrouped" : " grouped")
        case "restore":return "Codex location restored"
        default:return "Local preference saved"
        }
    }
    func setPreviewAccess(_ enabled:Bool) {
        send(["action":"mediaAccess","enabled":enabled])
    }
    func watch(_ ids:Set<String>,window:String="default") {
        guard windowWatches[window] != ids else {return}
        windowWatches[window]=ids
        watchedIDs=windowWatches.values.reduce(into:Set<String>()){$0.formUnion($1)}
        trimDetails()
        send(["action":"watch","window":window,"ids":Array(ids)])
    }
    func assign(_ id:String,to project:String) {send(["action":"assign","id":id,"project":project])}
    func open(_ id: String) {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "codex://threads/\(escaped)") else { return }
        if !NSWorkspace.shared.open(url) { error = "Codex could not open the session link. Ensure the Codex desktop app is installed." }
    }
    func stop() {
        guard !stopping else {return}
        composerAudio.stop()
        stopping = true
        _ = composerStore.flushLocalState()
        send(["action":"quit"])
        let handle=input,worker=process
        input=nil
        output?.readabilityHandler = nil
        // Drain queued writes before closing their handle, including the quit message.
        writeQueue.async {
            try? handle?.close()
            if worker?.isRunning == true {worker?.terminate()}
        }
    }
    func projectName(_ id: String) -> String { projectNames[id] ?? "Unassigned" }
}

func durationText(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(min(max(0, seconds), 1e12)) : 0
    return value >= 3600 ? "\(value / 3600)h \((value % 3600) / 60)m" : value >= 60 ? "\(value / 60)m \(value % 60)s" : "\(value)s"
}
func dateText(_ value: Double) -> String {
    guard value > 0 else { return "Unknown" }
    let date = Date(timeIntervalSince1970: value)
    if Calendar.current.isDateInToday(date) { return "Today " + date.formatted(.dateTime.hour().minute()) }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.day().month(.abbreviated))
}
func folderColour(_ name: String) -> Color {
    switch name { case "green": return .green; case "purple": return .purple; case "orange": return .orange; case "red": return .red; case "grey": return .gray; default: return .blue }
}

func countText(_ count:Int,_ noun:String)->String {"\(count) \(noun)" + (count == 1 ? "" : "s")}
