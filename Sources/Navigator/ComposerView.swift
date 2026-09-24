import SwiftUI
import AppKit

struct ComposerMessage:Decodable,Identifiable,Equatable {
    let id,role,text:String
    var attachments:[ComposerAttachment]?
    var phase:String?
    var startedAt:Double?
    var completedAt:Double?
    var durationSeconds:Double?
}

struct ComposerExchange:Identifiable {
    var id:String
    var messages:[ComposerMessage]
    var work:ComposerMessage? {messages.last(where:{$0.role == "Work"})}
    var prompts:[ComposerMessage] {messages.filter{$0.role == "You"}}
    func responseIDs(active:Bool)->Set<String> {
        let explicit=messages.filter{$0.role == "Codex" && $0.phase == "final_answer"}
        if !explicit.isEmpty {return Set(explicit.map(\.id))}
        guard !active,let last=messages.last(where:{$0.role == "Codex" && $0.phase != "commentary"}) else {return []}
        return [last.id]
    }
    static func group(_ messages:[ComposerMessage])->[ComposerExchange] {
        var result:[ComposerExchange]=[]
        for message in messages {
            if message.role == "You" || result.isEmpty {result.append(ComposerExchange(id:message.id,messages:[]))}
            result[result.count-1].messages.append(message)
        }
        return result
    }
}
struct ComposerOption:Decodable {let label,description:String}
struct ComposerQuestion:Decodable,Identifiable {let id,header,question:String;var isSecret:Bool?;var options:[ComposerOption]?}
struct ComposerApprovalChoice:Decodable,Identifiable {let id,label:String}
struct ComposerApproval:Decodable,Identifiable {let id,title,detail:String;let questions:[ComposerQuestion];let canAccept:Bool;var choices:[ComposerApprovalChoice]?}
struct ComposerModel:Decodable,Identifiable {let model,name:String;let efforts:[String];var defaultEffort:String?;var isDefault:Bool?;var id:String {model}}
struct ComposerSkill:Decodable,Identifiable {let name,path,description:String;let enabled:Bool;var id:String {path}}
struct ComposerPlugin:Decodable {let name:String;let enabled:Bool}
struct ComposerTokens:Decodable {let total,last:ComposerTokenCount;let modelContextWindow:Int?}
struct ComposerTokenCount:Decodable {let totalTokens:Int}
struct ComposerLimit:Decodable {let usedPercent:Double;let resetsAt:Double?}
struct ComposerTask:Decodable,Identifiable {
    let id,title,status:String
    let needsInput:Bool
    var category:String? = nil
}
struct ComposerState:Decodable {
    var tasks:[ComposerTask]?
    var taskKey:String?
    var observing:Bool?
    var threadId="",turnId="",title="New task",cwd="",project="",status="idle",error=""
    var voiceStatus:String?
    var voiceError:String?
    var voiceID:String?
    var workStartedAt:Double?
    var active=false
    var messages:[ComposerMessage]=[]
    var approvals:[ComposerApproval]=[]
    var effectiveModel:String?
    var effectiveEffort:String?
    var models:[ComposerModel]?
    var skills:[ComposerSkill]?
    var plugins:[ComposerPlugin]?
    var metadataLoading:Bool?
    var capabilityError:String?
    var tokenUsage:ComposerTokens?
    var fiveHourUsage:ComposerLimit?
    var revision=0
    var statusLabel:String {
        switch status {case "idle":return "Ready";case "starting":return "Starting…";case "reconnecting":return "Connecting…";case "running":return "Working…";case "approval":return "Needs your input";case "stopping":return "Stopping…";case "completed":return "Completed";case "interrupted":return "Stopped";case "failed":return "Failed";case "disconnected":return "Disconnected";default:return status.capitalized}
    }
}

final class ComposerStore:ObservableObject {
    @Published var state=ComposerState()
    @Published var attachments:[ComposerAttachment]=[] {didSet {saveEditor()}}
    @Published var draft="" {didSet {saveEditor()}}
    @Published var selectedModel="" {didSet {saveEditor()}}
    @Published var selectedEffort="" {didSet {saveEditor()}}
    @Published var selectedSkills:Set<String>=[] {didSet {saveEditor()}}
    @Published var submitting=false
    @Published var selectedPrompt:String?=nil {didSet {saveEditor()}}
    @Published var promptInstructions="" {didSet {saveEditor()}}
    @Published var preparedFeedback="" {didSet {saveEditor()}}
    @Published var reviewFeedback:[String:ReviewFeedback]=[:] {didSet {saveEditor()}}
    @Published private(set) var personalPrompts:[QuickPrompt]=[]
    @Published private(set) var localPersistenceError:String?
    private let localState:ComposerLocalState
    // The transient key protects text typed while the first Composer state is
    // still arriving from the worker. It is migrated to the new task exactly
    // once, without replacing an already recovered task editor.
    private var currentKey="new"
    private var restoring=false

    init(storageDirectory:URL?=nil) {
        localState=ComposerLocalState(storageDirectory:storageDirectory ?? ComposerLocalState.defaultDirectory())
        personalPrompts=localState.personalPrompts
        localState.setErrorHandler { [weak self] message in self?.localPersistenceError=message }
    }

    /// Model calls this for every Composer state envelope. It snapshots the old
    /// editor before replacing the task and restores only the matching task.
    func acceptState(_ value:ComposerState) {
        let next=value.taskKey ?? ""
        if next != currentKey {
            let transient=currentKey == "new" ? editor() : nil
            saveEditor()
            state=value
            currentKey=next
            if let transient,!localState.hasEditor(for:next),(!transient.draft.isEmpty || !transient.promptInstructions.isEmpty || !transient.preparedFeedback.isEmpty || !(transient.attachments ?? []).isEmpty) {
                localState.save(transient,for:next)
            }
            restoreEditor()
        } else { state=value }
        resolveModelSelection()
    }
    func resolveModelSelection() {
        let models=state.models ?? []
        guard !models.isEmpty else {return}
        if selectedModel.isEmpty {
            selectedModel=models.first(where:{$0.model == state.effectiveModel})?.model ?? models.first(where:{$0.isDefault == true})?.model ?? models[0].model
        }
        guard let entry=models.first(where:{$0.model == selectedModel}) else {return}
        if !entry.efforts.contains(selectedEffort) {
            let effective=selectedModel == state.effectiveModel ? state.effectiveEffort : nil
            selectedEffort=effective.flatMap{entry.efforts.contains($0) ? $0 : nil} ?? entry.defaultEffort ?? entry.efforts.first ?? ""
        }
    }
    func captureSubmission() -> ComposerSubmission {
        ComposerSubmission(taskKey:currentKey,text:submissionText,draft:draft,model:selectedModel,effort:selectedEffort,skills:selectedSkills.sorted(),selectedPrompt:selectedPrompt,promptInstructions:promptInstructions,preparedFeedback:preparedFeedback,attachments:attachments)
    }
    /// Clears a submitted editor only if this exact task and its captured text
    /// are still current. An uncertain/late acknowledgement therefore cannot
    /// erase a switched task or text typed after Send.
    func completeSubmission(_ submission:ComposerSubmission,accepted:Bool) {
        defer {submitting=false}
        guard accepted else {return}
        if submission.taskKey == currentKey {
            attachments.removeAll {attachment in submission.attachments.contains(where:{$0.id == attachment.id})}
            if draft == submission.draft {draft=""}
            if preparedFeedback == submission.preparedFeedback {preparedFeedback=""}
            if selectedPrompt == submission.selectedPrompt && promptInstructions == submission.promptInstructions {
                selectedPrompt=nil;promptInstructions=""
            }
            saveEditor()
        } else {
            // The acknowledgement belongs to an editor the user has switched
            // away from. Clear only its exact captured fields; never disturb
            // newer text subsequently typed in that task.
            var saved=localState.editor(for:submission.taskKey)
            var changed=false
            if let attached=saved.attachments {saved.attachments=attached.filter {attachment in !submission.attachments.contains(where:{$0.id == attachment.id})};changed = attached != saved.attachments}
            if saved.draft == submission.draft {saved.draft="";changed=true}
            if saved.preparedFeedback == submission.preparedFeedback {saved.preparedFeedback="";changed=true}
            if saved.selectedPrompt == submission.selectedPrompt && saved.promptInstructions == submission.promptInstructions {
                saved.selectedPrompt=nil;saved.promptInstructions="";changed=true
            }
            if changed {localState.save(saved,for:submission.taskKey)}
        }
    }
    func appendDictation(_ text:String,to key:String) {
        if key == currentKey {draft += (draft.isEmpty ? "" : "\n") + text}
        else {
            var saved=localState.editor(for:key)
            saved.draft += (saved.draft.isEmpty ? "" : "\n") + text
            localState.save(saved,for:key)
        }
    }
    func addAttachments(_ values:[ComposerAttachment],to key:String) {
        guard !key.isEmpty else {return}
        if key == currentKey {
            for value in values where !attachments.contains(where:{$0.path == value.path && $0.kind == value.kind}) {attachments.append(value)}
        } else {
            var saved=localState.editor(for:key)
            var attached=saved.attachments ?? []
            for value in values where !attached.contains(where:{$0.path == value.path && $0.kind == value.kind}) {attached.append(value)}
            saved.attachments=attached;localState.save(saved,for:key)
        }
    }
    func reloadLocalState() {
        // Do not save first: a restore deliberately replaces the local archive.
        localState.reload();personalPrompts=localState.personalPrompts;restoreEditor()
    }
    @discardableResult func flushLocalState() -> String? {
        saveEditor()
        do {try localState.flush();return nil}
        catch {return localState.lastError ?? "Composer editor could not be saved."}
    }
    func saveAsPersonalPrompt(title:String?=nil) {
        let text=draft.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else {return}
        let prompt=QuickPrompt(id:"personal-"+UUID().uuidString,title:(title?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false ? title! : "My prompt"),length:"Personal",text:text,isPersonal:true)
        personalPrompts.append(prompt);localState.savePersonalPrompts(personalPrompts)
    }
    func updatePersonalPrompt(_ prompt:QuickPrompt) {
        guard let index=personalPrompts.firstIndex(where:{$0.id == prompt.id}) else {return}
        personalPrompts[index]=prompt;localState.savePersonalPrompts(personalPrompts)
    }
    func deletePersonalPrompt(_ prompt:QuickPrompt) {
        personalPrompts.removeAll{$0.id == prompt.id};localState.savePersonalPrompts(personalPrompts)
        if selectedPrompt == prompt.id {selectedPrompt=nil;promptInstructions=""}
    }
    var prompts:[QuickPrompt] {QuickPrompt.standard + personalPrompts}
    var submissionText:String {
        preparedFeedback.isEmpty ? draft : preparedFeedback + (draft.isEmpty ? "" : "\n\nAdditional context:\n" + draft)
    }

    var workflow:String? {
        if draft.hasPrefix("Quick Prompt: "),let title=draft.split(separator:"\n").first {return String(title.dropFirst(14))}
        return state.messages.reversed().compactMap {message -> String? in
            guard message.role == "You",message.text.hasPrefix("Quick Prompt: ") else {return nil}
            return message.text.split(separator:"\n").first.map{String($0.dropFirst(14))}
        }.first
    }
    func select(_ prompt:QuickPrompt) {
        let block="Quick Prompt: " + prompt.title + "\n\n" + prompt.text + (prompt.id == "design" ? "\n\n" + DesignReview.instructions : "")
        // Replace only the exact, untouched inserted block. User edits survive.
        let context = !promptInstructions.isEmpty && draft.hasPrefix(promptInstructions)
            ? String(draft.dropFirst(promptInstructions.count)).trimmingCharacters(in:.whitespacesAndNewlines) : draft
        draft=block + (context.isEmpty ? "" : "\n\n" + context)
        selectedPrompt=prompt.id
        promptInstructions=block
    }
    private func editor() -> ComposerEditorState {ComposerEditorState(draft:draft,selectedModel:selectedModel,selectedEffort:selectedEffort,selectedSkills:Array(selectedSkills).sorted(),selectedPrompt:selectedPrompt,promptInstructions:promptInstructions,preparedFeedback:preparedFeedback,attachments:attachments,reviewFeedback:reviewFeedback)}
    private func saveEditor() {guard !restoring,!currentKey.isEmpty else {return};localState.save(editor(),for:currentKey)}
    private func restoreEditor() {
        restoring=true
        guard !currentKey.isEmpty else {
            attachments=[];draft="";selectedModel="";selectedEffort="";selectedSkills=[];selectedPrompt=nil;promptInstructions="";preparedFeedback="";reviewFeedback=[:]
            restoring=false;return
        }
        let saved=localState.editor(for:currentKey)
        attachments=saved.attachments ?? [];draft=saved.draft;selectedModel=saved.selectedModel;selectedEffort=saved.selectedEffort;selectedSkills=Set(saved.selectedSkills);selectedPrompt=saved.selectedPrompt;promptInstructions=saved.promptInstructions;preparedFeedback=saved.preparedFeedback;reviewFeedback=saved.reviewFeedback
        if let id=selectedPrompt,!promptInstructions.hasPrefix("Quick Prompt: "),let prompt=prompts.first(where:{$0.id == id}) {
            let block="Quick Prompt: " + prompt.title + "\n\n" + promptInstructions + (id == "design" ? "\n\n" + DesignReview.instructions : "")
            draft=block + (draft.isEmpty ? "" : "\n\n" + draft)
            promptInstructions=block
        }
        restoring=false
    }

    /// Executed by the native interaction probe. This exercises the real store
    /// rather than only the Codable editor value: submissions acknowledged
    /// after a task switch must clear the original task and a restored archive
    /// must replace memory without being overwritten first.
    static func localEditorRegression() -> Bool {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("navigator-composer-store-\(UUID().uuidString)",isDirectory:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=ComposerStore(storageDirectory:root)
        var first=ComposerState();first.taskKey="first";store.acceptState(first)
        store.draft="Submitted draft"
        let attachment=ComposerAttachment(path:"/tmp/fixture.png",name:"fixture.png",kind:"image")
        store.addAttachments([attachment],to:"first")
        let submission=store.captureSubmission()
        var second=ComposerState();second.taskKey="second";store.acceptState(second)
        store.draft="Other task draft"
        store.completeSubmission(submission,accepted:true)
        guard store.flushLocalState() == nil else {return false}
        let recovered=ComposerStore(storageDirectory:root)
        recovered.acceptState(first)
        guard recovered.draft.isEmpty && recovered.attachments.isEmpty else {return false}
        recovered.acceptState(second)
        guard recovered.draft == "Other task draft" else {return false}
        let replacement=ComposerLocalState(storageDirectory:root)
        replacement.save(ComposerEditorState(draft:"Restored draft"),for:"second")
        do {try replacement.flush()} catch {return false}
        recovered.reloadLocalState()
        return recovered.draft == "Restored draft"
    }

}
struct ComposerToolbarButton:View {
    @ObservedObject var store:ComposerStore
    let action:()->Void
    var body:some View {
        Button(action:action) {Image(systemName:store.state.active ? "ellipsis.bubble" : "square.and.pencil")}
            .help("Composer · " + store.state.statusLabel)
            .foregroundStyle(store.state.approvals.isEmpty && !(store.state.tasks ?? []).contains(where:{$0.needsInput}) ? Color.primary : Color.orange)
    }
}
struct ComposerView:View {
    @ObservedObject var store:ComposerStore
    @ObservedObject var surge:PurpleSurgeStore
    let returnToSession:(SurgeTaskStatus)->Void
    var onBack:(()->Void)? = nil
    private func closeComposer() {if let onBack {onBack()} else {dismiss()}}
    @EnvironmentObject var model:NavigatorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("navigator.textScale") private var textScale=1.0
    @StoredState private var followOutput=true
    @FocusState private var inputFocused:Bool
    @StoredState private var promptEditor:QuickPrompt?=nil
    private var state:ComposerState {store.state}
    private var canSend:Bool {!(state.taskKey ?? "").isEmpty && !state.active && state.observing != true && state.metadataLoading != true && state.status != "disconnected" && (!store.submissionText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !store.attachments.isEmpty) && !store.submitting}
    var body:some View {
        HStack(spacing:0) {
        VStack(spacing:0) {
            header
            Divider()
            conversation
            Divider()
            if let approval=state.approvals.first {
                ComposerApprovalCard(approval:approval).id(approval.id).environmentObject(model).padding(16)
                Divider()
            }
            input
        }
        .font(.system(size:14*textScale))
        .frame(minWidth:420,idealWidth:840,maxWidth:.infinity,minHeight:400,idealHeight:800,maxHeight:.infinity)
        PurpleSurgeDock(game:surge) { notice in
            if let notice, !notice.composer { closeComposer(); returnToSession(notice) }
            else {
                if let notice { model.send(["action":"composerSelect","key":notice.id]) }
                inputFocused=true
            }
        }
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .onAppear {surge.allowComposerSheet=true;DispatchQueue.main.async {inputFocused=true};registerProbe();model.send(["action":"composerRefresh"])}
        .onChange(of:state.taskKey) {_,_ in model.send(["action":"composerRefresh"])}
        .onDisappear {surge.allowComposerSheet=false;model.composerAudio.stop()}
        .onChange(of:state.revision) {_,_ in registerProbe()}
        .sheet(item:$promptEditor) {prompt in
            PersonalPromptEditor(prompt:prompt) {store.updatePersonalPrompt($0)}
        }
    }
    private var header:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Menu("Composer") {
                        let tasks=state.tasks ?? []
                        ForEach(["Active","Waiting","Completed"],id:\.self) {category in
                            let matching=tasks.filter {($0.category ?? taskCategory($0)) == category}
                            if !matching.isEmpty {
                                Section(category) {
                                    ForEach(matching) {task in
                                        Button(task.title + " · " + (task.needsInput ? "Needs your input" : task.status.capitalized)) {
                                            model.send(["action":"composerSelect","key":task.id])
                                        }
                                    }
                                }
                            }
                        }
                        if !state.active,let key=state.taskKey,!key.isEmpty {
                            Divider()
                            Button("Remove from Composer",role:.destructive) {model.send(["action":"composerRemoveTask","key":key])}.help("Hides this task and releases its idle connection. History, recovery files and the working folder are retained.")
                        }
                    }.font(.system(size:19*textScale,weight:.semibold)).fixedSize(horizontal:true,vertical:false)
                    Text(state.title).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !state.active {Text(state.statusLabel).foregroundStyle(.secondary)}
                if !state.threadId.isEmpty {Button("Open in Codex") {model.open(state.threadId)}}
                Button {closeComposer()} label: {Label("Sessions",systemImage:"chevron.left")}.keyboardShortcut(.cancelAction)
            }
            if let workflow=store.workflow {
                Label(workflow,systemImage:"sparkles").font(.system(size:12*textScale,weight:.semibold)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal,10).padding(.vertical,5).background(Color.accentColor.opacity(0.1),in:Capsule())
            }
            HStack(spacing:6) {
                Image(systemName:"folder")
                Text(state.cwd.isEmpty ? "A separate working folder will be created for this task." : state.cwd).font(.system(size:12*textScale)).lineLimit(2).textSelection(.enabled)
            }.foregroundStyle(.secondary)
            Text(state.threadId.isEmpty ? "New tasks can edit their working folder. Codex requests approval when it needs broader access." : "Model and effort choices apply to your next message. The task keeps its permission settings.")
                .font(.system(size:12*textScale)).foregroundStyle(.secondary)
        }.padding(18)
    }
    private var conversation:some View {
        ScrollViewReader {proxy in
            VStack(spacing:0) {
                HStack {
                    Text(state.messages.isEmpty ? "Describe what you want Codex to do." : "Recent conversation").foregroundStyle(.secondary)
                    Spacer()
                    if let message=state.messages.last(where:{DesignReview.parse($0.text) != nil}) {
                        Button("Recommendations") {proxy.scrollTo("recommendations-" + message.id,anchor:.top)}
                    }
                    Toggle("Follow response",isOn:$followOutput).toggleStyle(.checkbox)
                }.font(.system(size:12*textScale)).padding(.horizontal,18).padding(.vertical,10)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:18) {
                        let exchanges=ComposerExchange.group(state.messages)
                        ForEach(exchanges) {exchange in
                            let active=state.active && exchange.id == exchanges.last?.id
                            let responseIDs=exchange.responseIDs(active:active)
                            ForEach(exchange.prompts) {message in messageRow(message)}
                            ComposerWorkSection(exchange:exchange,active:active,status:state.statusLabel,
                                                startedAt:active ? state.workStartedAt : exchange.work?.startedAt,
                                                waiting:!state.approvals.isEmpty,textScale:textScale) {
                                ForEach(exchange.messages.filter{$0.role != "You" && $0.role != "Work" && !responseIDs.contains($0.id)}) {message in
                                    messageRow(message)
                                }
                            }
                            ForEach(exchange.messages.filter{responseIDs.contains($0.id)}) {message in messageRow(message)}
                        }
                        if state.active && exchanges.isEmpty {
                            HStack {ProgressView().controlSize(.small);Text(state.statusLabel)}
                                .foregroundStyle(.secondary).padding(14)
                        }
                        if !state.error.isEmpty {
                            VStack(alignment:.leading,spacing:8) {
                                Text(state.error).foregroundStyle(.red).textSelection(.enabled)
                                if state.status == "disconnected" {Button("Reconnect and check task") {model.send(["action":"composerReconnect"])}}
                            }.padding(12)
                        }
                        Color.clear.frame(height:1).id("composer-bottom")
                    }.padding(.horizontal,18).padding(.bottom,12)
                }
            }.onAppear {
                if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--review-next") {
                    DispatchQueue.main.asyncAfter(deadline:.now()+2) {proxy.scrollTo("recommendations-review-result",anchor:.top)}
                }
            }.onChange(of:state.revision) {_,_ in if followOutput {proxy.scrollTo("composer-bottom",anchor:.bottom)}}
        }
    }
    private func chooseAttachments() {
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=true;panel.allowsMultipleSelection=true
        let key=state.taskKey ?? ""
        panel.begin {response in
            guard response == .OK else {return}
            var errors:[String]=[]
            for url in panel.urls {do {store.addAttachments([try ComposerAttachmentImport.local(url)],to:key)} catch {errors.append(url.lastPathComponent+": "+error.localizedDescription)}}
            if !errors.isEmpty {model.error=errors.joined(separator:"\n")}
        }
    }
    private func messageRow(_ message:ComposerMessage)->some View {
                            VStack(alignment:.leading,spacing:6) {
                                Text(message.role).font(.system(size:13*textScale,weight:.semibold)).foregroundStyle(message.role == "You" ? Color.accentColor : .secondary)
                                if let attached=message.attachments,!attached.isEmpty {
                                    ScrollView(.horizontal) {HStack {ForEach(attached) {attachment in ComposerAttachmentTile(attachment:attachment,remove:nil)}}}
                                }
                                if message.role == "You",message.text.hasPrefix("Quick Prompt: ") {
                                    DisclosureGroup(message.text.split(separator:"\n").first.map(String.init) ?? "Quick Prompt") {
                                        Text(message.text).font(.system(size:12*textScale)).textSelection(.enabled)
                                    }
                                } else if ["Command","File changes","Activity","Thinking","Plan"].contains(message.role) {
                                    DisclosureGroup(message.text.split(separator:"\n").first.map(String.init) ?? message.role) {
                                        Text(message.text).font(.system(size:12*textScale,design:message.role == "Thinking" || message.role == "Plan" ? .default : .monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                                    }.font(.system(size:13*textScale))
                                } else if message.role == "Codex",let review=DesignReview.parse(message.text) {
                                    DesignReviewView(review:review,reviewID:message.id,feedback:Binding(get:{store.reviewFeedback[message.id] ?? ReviewFeedback()},set:{store.reviewFeedback[message.id]=$0})) {text in
                                        store.selectedPrompt=nil;store.promptInstructions=""
                                        store.preparedFeedback=text
                                        inputFocused=true
                                    }.disabled(state.active || store.submitting)
                                } else if message.role == "Codex" && state.active && store.workflow == "Evaluate Design" && (message.text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("{") || message.text.hasPrefix("```json")) {
                                    Text("Preparing your design review…").foregroundStyle(.secondary)
                                } else if message.role == "Codex" && (!state.active || message.phase == "final_answer") {
                                    LinkedText(text:message.text).frame(maxWidth:.infinity,alignment:.leading)
                                } else {
                                    Text(message.text.isEmpty ? "…" : message.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                                }
                                if message.role == "Codex" && !message.text.isEmpty {
                                    Button {NSPasteboard.general.clearContents();NSPasteboard.general.setString(message.text,forType:.string)} label: {Label("Copy",systemImage:"doc.on.doc")}
                                        .buttonStyle(.borderless).font(.caption).help("Copy response")
                                }
                            }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                            .background(message.role == "You" ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
    }
    private var input:some View {
        VStack(alignment:.leading,spacing:10) {
            if let persistenceError=store.localPersistenceError {
                Text(persistenceError).font(.system(size:12*textScale)).foregroundStyle(.red).textSelection(.enabled)
            }
            runtimeControls
            DisclosureGroup("Quick Prompts") {
                LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:6) {
                    ForEach(store.prompts) {prompt in
                        Button {
                            store.select(prompt)
                            inputFocused=true
                        } label: {
                            HStack {if store.selectedPrompt == prompt.id {Image(systemName:"checkmark.circle.fill")};Text(prompt.title);Spacer();Text(prompt.length).foregroundStyle(.secondary);if prompt.isPersonal {Image(systemName:"person.fill").foregroundStyle(.secondary)}}
                                .font(.system(size:12*textScale)).frame(maxWidth:.infinity)
                        }.help("Choose " + prompt.title + ". Your context is preserved.")
                        .disabled(state.active || store.submitting)
                        .contextMenu {
                            if prompt.isPersonal {
                                Button("Rename / edit…") {promptEditor=prompt}
                                Button("Delete",role:.destructive) {store.deletePersonalPrompt(prompt)}
                            }
                        }
                    }
                }
                Button("Save draft as my prompt") {store.saveAsPersonalPrompt()}
                    .disabled(store.draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || store.submitting)
                Text("Quick Prompts insert editable text below. Right-click a personal prompt to edit it.")
                    .font(.system(size:11*textScale)).foregroundStyle(.secondary)
            }
            if !store.preparedFeedback.isEmpty {
                HStack(alignment:.top) {
                    DisclosureGroup("Selected work & feedback · ready to send") {
                        TextEditor(text:$store.preparedFeedback).font(.system(size:12*textScale)).frame(height:100)
                    }
                    Button("Clear") {store.preparedFeedback=""}
                }
            }
            HStack {
                Button {chooseAttachments()} label: {Label("Attach",systemImage:"paperclip")}
                Text("Drop files, images, folders, or links here").font(.system(size:11*textScale)).foregroundStyle(.secondary)
                Spacer()
            }
            if !store.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {ForEach(store.attachments) {attachment in ComposerAttachmentTile(attachment:attachment) {store.attachments.removeAll {$0.id == attachment.id}}}}
                }.frame(height:82)
            }
            ComposerAudioControls(audio:model.composerAudio,store:store).environmentObject(model)
            ComposerPromptEditor(text:$store.draft,fontSize:15*textScale,enabled:!store.submitting,taskKey:state.taskKey ?? "",onAttachments:{key,attachments,error in
                store.addAttachments(attachments,to:key)
                if let error {model.error=error}
            }).focused($inputFocused)
                .padding(8).frame(height:state.messages.contains(where:{DesignReview.parse($0.text) != nil}) ? 55 : state.active ? 65 : 100)
                .background(Color(nsColor:.textBackgroundColor),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Prompt for Codex")
            HStack(alignment:.center) {
                Text("Submitted prompts and task context are sent through Codex to its model provider. File previews stay local.")
                    .font(.system(size:12*textScale)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer(minLength:16)
                if state.active {
                    Button("Stop") {model.send(["action":"composerStop"])}.disabled(state.status == "stopping" || state.observing == true)
                } else {
                    Button("Send to Codex") {send()}.keyboardShortcut(.return,modifiers:.command).buttonStyle(.borderedProminent).disabled(!canSend)
                }
            }
            if state.active {Text("You can close Composer and keep browsing. Reopen it from the toolbar; closing Navigator disconnects the task.").font(.system(size:12*textScale)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        }.padding(18)
    }
    private var runtimeControls:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Picker("Model",selection:$store.selectedModel) {
                    if (state.models ?? []).isEmpty {Text(state.metadataLoading == true ? "Loading models…" : "Models unavailable").tag("")}
                    if !store.selectedModel.isEmpty && !(state.models ?? []).contains(where:{$0.model == store.selectedModel}) {Text(store.selectedModel).tag(store.selectedModel)}
                    ForEach(state.models ?? []) {entry in Text(entry.model).tag(entry.model)}
                }.frame(maxWidth:330)
                Picker("Effort",selection:$store.selectedEffort) {
                    if store.selectedEffort.isEmpty {Text("Effort unavailable").tag("")}
                    ForEach((state.models ?? []).first(where:{$0.model == store.selectedModel})?.efforts ?? [],id:\.self) {effort in Text(effort.capitalized).tag(effort)}
                }.frame(maxWidth:220).disabled(store.selectedModel.isEmpty)
                Spacer()
                Button {model.send(["action":"composerRefresh"])} label: {Image(systemName:"arrow.clockwise")}.help("Refresh models, skills, plugins and account usage")
            }.disabled(state.active || store.submitting || state.metadataLoading == true)
                .onChange(of:store.selectedModel) {_,_ in store.resolveModelSelection()}
            HStack(spacing:18) {
                Text(state.tokenUsage.map{"Tokens: " + $0.total.totalTokens.formatted()} ?? "Tokens: unavailable")
                Text(contextUsage)
                if let limit=state.fiveHourUsage {
                    Text("5-hour usage: \(limit.usedPercent, specifier:"%.0f")%")
                        .help(limit.resetsAt.map{"Resets " + Date(timeIntervalSince1970:$0).formatted()} ?? "Reset time unavailable")
                } else {Text("5-hour usage: unavailable")}
                if state.metadataLoading == true {ProgressView().controlSize(.small)}
            }.font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Skills & plugins" + (store.selectedSkills.isEmpty ? "" : " · \(store.selectedSkills.count) selected")) {
                ScrollView {
                    VStack(alignment:.leading,spacing:8) {
                        ForEach(state.skills ?? []) {skill in
                            Toggle(isOn:Binding(get:{store.selectedSkills.contains(skill.path)},set:{if $0 {store.selectedSkills.insert(skill.path)} else {store.selectedSkills.remove(skill.path)}})) {
                                VStack(alignment:.leading) {Text(skill.name);Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)}
                            }.toggleStyle(.checkbox).disabled(!skill.enabled || state.active || store.submitting)
                        }
                        if (state.skills ?? []).isEmpty {Text("No skills reported for this working folder.").foregroundStyle(.secondary)}
                        ForEach(Array((state.plugins ?? []).enumerated()),id:\.offset) {_,plugin in
                            Label(plugin.name + (plugin.enabled ? " · enabled" : " · disabled"),systemImage:"puzzlepiece.extension")
                        }
                        Text("Select skills to include with your next message. Enabled plugins are managed by Codex; describe which plugin you want to use in your prompt. Install or connect plugins in Codex, then refresh here.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:150)
            }
            if let error=state.capabilityError,!error.isEmpty {Text(error).font(.caption).foregroundStyle(.secondary)}
        }
    }
    private var contextUsage:String {
        guard let usage=state.tokenUsage,let window=usage.modelContextWindow,window>0 else {return "Context: unavailable"}
        return "Context: \(Int(Double(usage.last.totalTokens)/Double(window)*100))% · \(usage.last.totalTokens.formatted()) / \(window.formatted())"
    }
    private func send() {guard canSend else {return};model.submitComposer();followOutput=true}
    private func taskCategory(_ task:ComposerTask)->String {
        if task.needsInput {return "Waiting"}
        return ["starting","reconnecting","running","approval","stopping"].contains(task.status) ? "Active" : "Completed"
    }
    private func registerProbe() {
        guard InteractionProbe.enabled else {return}
        InteractionProbe.values["quickPromptReplacement"]={
            let sample=ComposerStore();sample.draft="Keep the activity chart visible."
            sample.select(QuickPrompt.standard[0]);sample.select(QuickPrompt.standard[2]);sample.select(QuickPrompt.standard[2])
            return sample.draft.hasSuffix("Keep the activity chart visible.") && sample.submissionText == sample.draft && !sample.submissionText.contains("280 characters") && sample.submissionText.components(separatedBy:"Quick Prompt:").count == 2 && sample.submissionText.contains(DesignReview.instructions) && ComposerStore.localEditorRegression()
        }
        InteractionProbe.values["quickPromptEdits"]={
            let root=FileManager.default.temporaryDirectory.appendingPathComponent("navigator-prompt-check-"+UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            let sample=ComposerStore(storageDirectory:root)
            var state=ComposerState();state.taskKey="prompt-check";sample.acceptState(state)
            sample.draft="My context";sample.select(QuickPrompt.standard[0])
            sample.draft=sample.draft.replacingOccurrences(of:QuickPrompt.standard[0].text,with:"My edited instructions")
            sample.select(QuickPrompt.standard[1])
            guard sample.draft.contains("My edited instructions"),sample.draft.contains("My context"),sample.submissionText==sample.draft else {return false}
            let old=ComposerLocalState(storageDirectory:root)
            old.save(ComposerEditorState(draft:"Legacy context",selectedPrompt:QuickPrompt.standard[0].id,promptInstructions:"Legacy instructions"),for:"legacy")
            do {try old.flush()} catch {return false}
            let restored=ComposerStore(storageDirectory:root);state.taskKey="legacy";restored.acceptState(state)
            return restored.draft.contains("Legacy instructions") && restored.draft.contains("Legacy context") && restored.submissionText==restored.draft
        }
        InteractionProbe.values["composerTimeline"]={
            let messages=[
                ComposerMessage(id:"user",role:"You",text:"Check the task"),
                ComposerMessage(id:"thought",role:"Thinking",text:"Checking the task"),
                ComposerMessage(id:"comment",role:"Codex",text:"Progress",phase:"commentary"),
                ComposerMessage(id:"work",role:"Work",text:"",durationSeconds:94),
                ComposerMessage(id:"answer",role:"Codex",text:"Done",phase:"final_answer")
            ]
            let groups=ComposerExchange.group(messages)
            let sample=ComposerStore()
            var first=ComposerState();first.taskKey="first";sample.acceptState(first)
            var second=ComposerState();second.taskKey="second";sample.acceptState(second)
            sample.draft="Keep this draft"
            sample.appendDictation("Spoken words",to:"first")
            guard sample.draft=="Keep this draft" else {return false}
            sample.acceptState(first)
            return groups.count==1 && groups[0].work?.durationSeconds==94 &&
                groups[0].responseIDs(active:false)==["answer"] &&
                groups[0].responseIDs(active:true)==["answer"] && sample.draft.contains("Spoken words")
        }
        InteractionProbe.values["reviewDraftScope"]={
            let sample=ComposerStore();sample.draft="My extra context";sample.preparedFeedback="Selected work"
            return sample.submissionText == "Selected work\n\nAdditional context:\nMy extra context"
        }
        InteractionProbe.values["composerAttachments"]={ComposerAttachmentCheck.run(store:store)}
        InteractionProbe.actions["composerSend"]={model.composerDraft="Demonstrate approval handling";model.submitComposer()}
        InteractionProbe.actions["composerAccept"]={if let a=model.composer.approvals.first {model.send(["action":"composerReply","token":a.id,"accept":true])}}
        InteractionProbe.actions["composerStop"]={model.send(["action":"composerStop"])}
        InteractionProbe.actions["composerClose"]={closeComposer()}
        InteractionProbe.values["composerApproval"]={!model.composer.approvals.isEmpty}
        InteractionProbe.values["composerComplete"]={model.composer.status == "completed" && model.composer.messages.contains{$0.role == "Codex"}}
        InteractionProbe.values["composerStopped"]={model.composer.status == "interrupted"}
    }
}

private struct PersonalPromptEditor:View {
    @Environment(\.dismiss) private var dismiss
    let original:QuickPrompt
    let save:(QuickPrompt)->Void
    @StoredState private var title=""
    @StoredState private var text=""
    init(prompt:QuickPrompt,save:@escaping (QuickPrompt)->Void) {
        original=prompt;self.save=save;_title=StoredState(initialValue:prompt.title);_text=StoredState(initialValue:prompt.text)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("My prompt").font(.headline)
            TextField("Title",text:$title)
            TextEditor(text:$text).font(.system(size:13)).frame(width:460,height:220).border(Color.secondary.opacity(0.25))
            HStack {Spacer();Button("Cancel") {dismiss()};Button("Save") {save(QuickPrompt(id:original.id,title:title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "My prompt" : title,length:"Personal",text:text,isPersonal:true));dismiss()}.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}
        }.padding(20)
    }
}

private struct ComposerApprovalCard:View {
    @EnvironmentObject var model:NavigatorModel
    @AppStorage("navigator.textScale") private var textScale=1.0
    let approval:ComposerApproval
    @StoredState private var answers:[String:String]=[:]
    @StoredState private var sending=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Label(approval.title,systemImage:"hand.raised").font(.system(size:14*textScale,weight:.semibold))
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    if approval.questions.isEmpty {
                        Text(approval.detail).font(.system(size:14*textScale)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    } else {
                        ForEach(approval.questions) {question in
                            VStack(alignment:.leading,spacing:8) {
                                Text(question.question)
                                if let options=question.options {
                                    ForEach(options.indices,id:\.self) {i in
                                        Button {answers[question.id]=options[i].label} label: {
                                            HStack(alignment:.top) {Image(systemName:answers[question.id] == options[i].label ? "largecircle.fill.circle" : "circle");Text(options[i].label+" — "+options[i].description).multilineTextAlignment(.leading)}
                                        }.buttonStyle(.plain)
                                    }
                                }
                                if question.isSecret == true {SecureField("Your answer",text:answer(question.id))}
                                else {TextField("Your answer",text:answer(question.id),axis:.vertical).lineLimit(1...4)}
                            }
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:150)
            HStack {
                if approval.questions.isEmpty {
                    Button("Decline") {reply(false)}
                    Spacer()
                    ForEach(approval.choices ?? []) {choice in
                        Button(choice.label) {reply(true,choice:choice.id)}
                    }
                    Button("Allow once") {reply(true)}.buttonStyle(.borderedProminent).disabled(!approval.canAccept)
                } else {
                    Spacer()
                    Button("Send answers") {reply(true)}.disabled(approval.questions.contains{(answers[$0.id] ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty})
                }
            }
        }.disabled(sending).padding(16).background(Color.orange.opacity(0.1),in:RoundedRectangle(cornerRadius:10))
    }
    private func answer(_ id:String)->Binding<String> {Binding(get:{answers[id] ?? ""},set:{answers[id]=$0})}
    private func reply(_ accept:Bool,choice:String="") {
        sending=true
        model.perform(["action":"composerReply","token":approval.id,"accept":accept,"answers":answers,"choice":choice],undoManager:nil) {error in
            sending=false
            if let error {model.error=error}
        }
    }
}
