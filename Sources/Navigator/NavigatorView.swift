import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers
import QuickLookThumbnailing

// Explicit property-wrapper alias avoids the newer SDK State macro overload.
typealias StoredState<Value> = SwiftUI.State<Value>

struct ProjectSection:Identifiable {let id,name:String;var projects:[Project]}

struct NavigatorView: View {
    @EnvironmentObject var model: NavigatorModel
    @StateObject private var appearance=AppAppearance.shared
    @StateObject private var surge = PurpleSurgeStore()
    @AppStorage("navigator.theme") private var theme = "System"
    @AppStorage("navigator.view") private var mode = "Overview"
    @AppStorage("navigator.textScale") private var textScale=1.0
    @AppStorage("navigator.density") private var density="Comfortable"
    @StoredState private var windowID=UUID().uuidString
    @StoredState private var visibleSessions:[Session]=[]
    @StoredState private var columnSizes:[String:Double]=[:]
    @FocusState private var searchFocused:Bool
    @StoredState private var metadataExpanded=false
    @StoredState private var scope = "all"
    @StoredState private var search = ""
    @StoredState private var selected: String?
    @StoredState private var selectedSessionIDs:Set<String>=[]
    @StoredState private var sessionAnchor:String?
    @StoredState private var activityDate:Date?
    @StoredState private var conversationTarget:ConversationTarget?
    @StoredState private var librarySettings=false
    @StoredState private var searchHits:[SearchHit]=[]
    @StoredState private var searchResultQuery=""
    @StoredState private var searchLoading=false
    @StoredState private var searchIncomplete=false
    @StoredState private var searchTruncated=false
    @StoredState private var searchFailure:String?
    @StoredState private var searchGeneration=0
    @StoredState private var launchRevision=0
    @StoredState private var appearedRows:Set<String>=[]
    @StoredState private var expanded: Set<String> = []
    @StoredState private var promptLimits:[String:Int]=[:]
    @StoredState private var reversed: Set<String> = []
    @StoredState private var sort = "Modified"
    @StoredState private var descending = true
    @StoredState private var days = 0
    @StoredState private var sessionType = "All types"
    @StoredState private var sidebarWidth = NavigatorApp.preferences.object(forKey:"navigator.sidebarWidth") as? Double ?? 218.0
    @StoredState private var inspectorWidth = NavigatorApp.preferences.object(forKey:"navigator.inspectorWidth") as? Double ?? 300.0
    @StoredState private var activityHeight = NavigatorApp.preferences.object(forKey:"navigator.activityHeight") as? Double ?? 112.0
    @StoredState private var voiceOrganizer = false
    @AppStorage("navigator.projectSort") private var projectSort = "Alphabetical"
    @AppStorage("navigator.customProjectOrder") private var customProjectOrder = "[]"
    @AppStorage("navigator.nameFillsSpace") private var nameFillsSpace = true
    @AppStorage("navigator.columns") private var columnOrder = "Modified|Active time|Size|Media"
    @AppStorage("navigator.columnWidths") private var savedWidths = "{}"
    @StoredState private var draggingColumn: String?
    @StoredState private var draggingProjects = false
    @AppStorage("navigator.unassignedExpanded") private var unassignedExpanded=false
    @StoredState private var sidebarSelection:String?
    @StoredState private var logoProject: Project?
    @StoredState private var grouping = false
    @StoredState private var selectedProjects: Set<String> = []
    @StoredState private var groupingProjects: Set<String> = []
    @StoredState private var groupName = ""
    private let allColumns = ["Modified","Active time","Size","Media","Prompts","Date Created","Token Usage"]
    private var columns: [String] { columnOrder.split(separator:"|").map(String.init).filter { allColumns.contains($0) } }
    private var widths:[String:Double] {columnSizes}
    private func width(_ name:String) -> CGFloat {
        let base=widths[name] ?? (name == "Name" ? 310 : name == "Media" ? 75 : 125)
        if name == "Name" {return base}
        return max(base,(name == "Media" ? 65 : 110)*textScale)
    }
    private var tableWidth: CGFloat { width("Name") + columns.reduce(0) { $0 + width($1) } + 36 }
    private var sortedProjects: [Project] {
        let ids=ProjectOrder.decode(customProjectOrder)
        let ranks=Dictionary(ids.enumerated().map{($0.element,$0.offset)},uniquingKeysWith:min)
        return model.projects.sorted { a,b in
            if projectSort == "Custom" {
                let ai=ranks[a.id] ?? Int.max,bi=ranks[b.id] ?? Int.max
                if ai != bi {return ai<bi}
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            if a.pinned != b.pinned { return a.pinned }
            let sa=model.projectStats[a.id] ?? ProjectStats(),sb=model.projectStats[b.id] ?? ProjectStats()
            if projectSort == "Last updated" {
                let va = sa.modified, vb = sb.modified
                if va != vb { return va > vb }
            }
            if projectSort == "Biggest" {
                let va = sa.size, vb = sb.size
                if va != vb { return va > vb }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    @StoredState private var minimumDuration = 0
    @StoredState private var mediaOnly = false
    @StoredState private var runningOnly = false
    @StoredState private var quickLook = false
    @AppStorage("navigator.inspectorVisible") private var inspectorVisible=true
    @StoredState private var composerPresented=false
    @StoredState private var composerActive=false
    @StoredState private var inspectorComposer=ComposerState()
    @StoredState private var newProjectPresented=false
    @StoredState private var newSessionPresented=false
    @StoredState private var rename = false
    @StoredState private var dropTarget: String?
    @StoredState private var showOptions = false
    @StoredState private var previewAccessSetup = false
    @StoredState private var accessSetupChecked = false
    @StoredState private var tableFocused=false

    private var session: Session? { filtered.first { $0.id == selected } }
    private var project: Project? { model.projects.first { $0.id == scope } }
    private var title: String {
        switch scope { case "all": return "All Sessions"; case "recent": return "Recent"; case "favourites": return "Favourites"; case "archived": return "Archived"; case "unassigned": return "Unassigned"; default: return project?.name ?? "Sessions" }
    }
    private var filtered:[Session] {visibleSessions}
    private func computeFiltered(ignoreActivity:Bool=false) -> [Session] {
        let now=Date()
        let values = model.sessions.filter { s in
            let inScope: Bool
            switch scope {
            case "all": inScope = !s.archived
            case "recent": inScope = !s.archived && now.timeIntervalSince1970-s.modified < 7*86400
            case "favourites": inScope = s.favourite && !s.archived
            case "archived": inScope = s.archived
            default: inScope = s.project == scope && !s.archived
            }
            return inScope && (search.isEmpty || s.title.localizedCaseInsensitiveContains(search) || model.projectName(s.project).localizedCaseInsensitiveContains(search) || s.searchText.localizedCaseInsensitiveContains(search) || (searchResultQuery == search && searchHits.contains{$0.threadID == s.id}))
                && (ignoreActivity || activityDate == nil || SessionSelection.hasActivity(day:activityDate!,intervals:(model.activity[s.id] ?? []).map{($0.start,$0.end,$0.seconds)},running:s.running,now:now))
                && (days == 0 || now.timeIntervalSince1970-s.modified < Double(days*3600))
                && (minimumDuration == 0 || s.duration(at: now) >= Double(minimumDuration))
                && (sessionType == "All types" || s.sessionType == sessionType)
                && (!mediaOnly || s.mediaCount > 0) && (!runningOnly || s.running)
        }
        return values.sorted { a,b in
            let result: ComparisonResult
            switch sort {
            case "Name": result = a.title.localizedStandardCompare(b.title)
            case "Active time": result = compare(a.duration(at: now),b.duration(at: now))
            case "Prompts": result = compare(Double(a.promptCount),Double(b.promptCount))
            case "Date Created": result = compare(a.created,b.created)
            case "Token Usage": result = compare(Double(a.tokenUsage ?? -1),Double(b.tokenUsage ?? -1))
            case "Size": result = compare(Double(a.size),Double(b.size))
            case "Media": result = compare(Double(a.mediaCount),Double(b.mediaCount))
            default: result = compare(a.modified,b.modified)
            }
            if result == .orderedSame { return a.id < b.id }
            return descending ? result == .orderedDescending : result == .orderedAscending
        }
    }

    var body: some View {presentedContent}
    private var layout:some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
            let gameWidth: CGFloat = surge.open ? (surge.introduction ? 328 : 360) : 40
            let available = geometry.size.width - gameWidth
            let left = min(max(sidebarWidth,170*textScale),max(170*textScale,available - (mode == "Overview" && !surge.open ? 654 : 434)))
            let right = min(inspectorWidth,max(220,available - left - 434))
            HStack(spacing:0) {
                sidebar.frame(width:left)
                PanelDivider(value:$sidebarWidth,limits:(170*textScale)...max(170*textScale,available - (mode == "Overview" && !surge.open ? right + 434 : 434)))
                Group {
                if composerPresented {
                    ComposerView(store:model.composerStore,surge:surge,returnToSession:{returnFromSurge($0)},onBack:{composerPresented=false}).environmentObject(model)
                } else {
                VStack(spacing: 0) {
                    if mode == "Overview" {
                        overviewHeader(maxHeight:max(80,geometry.size.height-340))
                        if showActivity {HeightDivider(value:$activityHeight,limits:80...max(80,geometry.size.height-340))}
                    }
                    filters
                    contextualBar
                    table.background(KeyboardSurface(active:$tableFocused,label:"Sessions") {code in
                        switch code {
                        case 49:guard session != nil else {return false};tableFocused=false;quickLook=true;return true
                        case 36:guard let session else {return false};openComposer(session:session);return true
                        case 125:moveSelection(1);return true
                        case 126:moveSelection(-1);return true
                        case 115:if let id=filtered.first?.id {selectSession(id)};return true
                        case 119:if let id=filtered.last?.id {selectSession(id)};return true
                        default:return false
                        }
                    })
                }
                }
                }.frame(minWidth:420,maxWidth: .infinity, maxHeight: .infinity)
                if mode == "Overview" && !surge.open && inspectorVisible {
                    PanelDivider(value:$inspectorWidth,limits:220...max(220,available-left-434),direction:-1)
                    inspector.frame(width:right)
                }
                if !composerPresented { PurpleSurgeDock(game:surge,returnToTask:returnFromSurge) }

            }}
            Divider()
            HStack(spacing: 8) {
                Circle().fill(model.connected ? Color.green : Color.orange).frame(width: 6,height: 6)
                Text(model.message).lineLimit(1)
                Spacer()
                Text(countText(filtered.count,"session"))
                Text("·  Space to preview  ·  Double-click to open").foregroundStyle(.secondary)
            }.font(.system(size:13*textScale)).foregroundStyle(.secondary).padding(.horizontal,18).frame(height: 29)
        }
    }
    private var observedContent:some View {
        layout.background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme,appearance.scheme)
        .task(id:sidebarWidth) {do {try await Task.sleep(nanoseconds:250_000_000);NavigatorApp.preferences.set(sidebarWidth,forKey:"navigator.sidebarWidth")} catch {}}
        .task(id:inspectorWidth) {do {try await Task.sleep(nanoseconds:250_000_000);NavigatorApp.preferences.set(inspectorWidth,forKey:"navigator.inspectorWidth")} catch {}}
        .task(id:activityHeight) {do {try await Task.sleep(nanoseconds:250_000_000);NavigatorApp.preferences.set(activityHeight,forKey:"navigator.activityHeight")} catch {}}
        .onReceive(model.composerStore.$state) {value in
            // Composer can publish its initial state while its sheet is being
            // inserted. Update the shared drawer on the next UI turn, outside
            // that layout transaction.
            DispatchQueue.main.async {
                inspectorComposer=value
                if composerActive != value.active { composerActive=value.active }
                updateSurgeTasks(model.composer)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("NavigatorAttentionSelected"))) {notice in
            if let key=notice.object as? String {
                if key.hasPrefix("session:"),let session=model.sessions.first(where:{$0.id == String(key.dropFirst(8))}) {openComposer(session:session)}
                else {model.send(["action":"composerSelect","key":String(key.dropFirst(9))]);composerPresented=true}
            }
        }
        .onChange(of:model.revision) {_,_ in updateSurgeTasks(model.composer)}
        .onChange(of:theme) {_,value in appearance.setTheme(value)}
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("NavigatorSnapshotFinished"))) { _ in
            if CommandLine.arguments.contains("--demo") {quickLook=false;voiceOrganizer=false;logoProject=nil;grouping=false;previewAccessSetup=false;composerPresented=false}
        }
    }
    private var filteredContent:some View {
        observedContent.onChange(of: selected) { _,value in
            if let value,!selectedSessionIDs.contains(value) {selectedSessionIDs=[value];sessionAnchor=value}
            if value == nil {selectedSessionIDs=[]}
            watch()
        }
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("NavigatorLaunchChanged"))) {_ in launchRevision+=1}
        .onChange(of:activityDate) {_,_ in refreshVisible()}
        .onChange(of: expanded) { _,_ in watch() }
        .onChange(of: inspectorComposer.threadId) { _,_ in watch() }
        .onChange(of: composerPresented) { _,_ in watch() }
        .onChange(of:appearedRows) {_,_ in watch()}
        .onChange(of:model.revision) {_,_ in refreshVisible()}
        .task(id:search + ":" + String(model.revision)) {
            do {try await Task.sleep(nanoseconds:120_000_000);refreshVisible();findPassages()} catch {}
        }
        .onReceive(Timer.publish(every:30,on:.main,in:.common).autoconnect()) {_ in if days>0 || minimumDuration>0 || scope=="recent" || filtered.contains(where:{$0.running}) {refreshVisible()}}
        .onChange(of:days) {_,_ in refreshVisible()}
        .onChange(of:minimumDuration) {_,_ in refreshVisible()}
        .onChange(of:sessionType) {_,_ in refreshVisible()}
        .onChange(of:mediaOnly) {_,_ in refreshVisible()}
        .onChange(of:runningOnly) {_,_ in refreshVisible()}
        .onChange(of:sort) {_,_ in refreshVisible()}
        .onChange(of:descending) {_,_ in refreshVisible()}
        .onDisappear {model.watch([],window:windowID)}
        .onChange(of: scope) { _,_ in selected = nil;selectedSessionIDs=[];sessionAnchor=nil;expanded=[];refreshVisible();if let id=sidebarSelection {selected=id;sidebarSelection=nil} }
    }
    private var presentedContent:some View {
        filteredContent.disabled(model.libraryBusy).onReceive(NotificationCenter.default.publisher(for:Notification.Name("NavigatorLibraryRestored"))) {_ in columnSizes=(try? JSONDecoder().decode([String:Double].self,from:Data((NavigatorApp.preferences.string(forKey:"navigator.columnWidths") ?? "{}").utf8))) ?? [:]}.onAppear {configureOnAppear()}
        .background(SearchRegistration(action:{searchFocused=true}))
        .font(.system(size:14*textScale))
        .sheet(isPresented: $quickLook,onDismiss:{tableFocused=true}) {
            if let s=session {SessionPreview(session:s,projectName:model.projectName(s.project),detail:model.details[s.id])}
        }
        .sheet(isPresented:$newProjectPresented) {
            NewProjectView {created in
                scope=created.id;selectedProjects=[];selected=nil;selectedSessionIDs=[];search="";composerPresented=false;refreshVisible()
            }.environmentObject(model)
        }
        .sheet(isPresented:$newSessionPresented) {
            NewSessionView(projects:sortedProjects,initialProject:project?.id) {target in openComposer(target:target)}
        }
        .sheet(isPresented:$previewAccessSetup) {PreviewAccessSetup().environmentObject(model)}
        .sheet(item:$conversationTarget) {target in ConversationReader(target:target).environmentObject(model)}
        .sheet(isPresented:$librarySettings) {LibrarySettingsView().environmentObject(model)}
        .overlay(alignment:.bottom) {
            if let notice=model.localNotice {
                HStack(spacing:12) {
                    Image(systemName:"checkmark.circle.fill").foregroundStyle(.green)
                    Text(notice.message).lineLimit(2)
                    Button("Undo",action:notice.undo).buttonStyle(.borderless)
                    Button {model.localNotice=nil} label:{Image(systemName:"xmark")}.buttonStyle(.plain).help("Dismiss confirmation")
                }.font(.callout).padding(.horizontal,16).padding(.vertical,12)
                    .background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Color(nsColor:.separatorColor).opacity(0.5)))
                    .shadow(color:.black.opacity(0.12),radius:10,y:4).padding(.bottom,40).padding(.horizontal,20).frame(maxWidth:650)
            }
        }
        .sheet(isPresented:$voiceOrganizer) {VoiceOrganizer().environmentObject(model)}
        .sheet(item:$logoProject) { p in LogoEditor(project:p).environmentObject(model) }
        .sheet(isPresented:$grouping) {
            ProjectGroupingView(projects:sortedProjects,save:{ ids,name,completion in
                model.perform(["action":"groupProjects","ids":Array(ids),"name":name],completion:completion)
            },selection:$groupingProjects,name:$groupName)
        }
        .alert("Navigator", isPresented: Binding(get: {model.error != nil}, set: {if !$0 {model.error = nil}})) {
            Button("OK") {model.error = nil}
        } message: { Text(model.error ?? "") }
        .sheet(isPresented:$rename) {
            if let session {RenameEditor(session:session).environmentObject(model)}
        }
    }

    private func updateSurgeTasks(_ composer: ComposerState) {
        var tasks = (composer.tasks ?? []).map { SurgeTaskStatus(id:$0.id,status:$0.needsInput ? "approval" : $0.status,composer:true) }
        if let key = composer.taskKey, !key.isEmpty {
            tasks.removeAll { $0.id == key }
            tasks.append(SurgeTaskStatus(id:key,status:composer.approvals.isEmpty ? composer.status : "approval",composer:true))
        }
        tasks += model.sessions.filter { $0.id != composer.threadId }.map { SurgeTaskStatus(id:$0.id,status:$0.status,composer:false) }
        AttentionNotifications.shared.update(tasks:tasks.map {task in
            let title=task.composer ? ((composer.tasks ?? []).first(where:{$0.id == task.id})?.title ?? composer.title) : (model.sessions.first(where:{$0.id == task.id})?.title ?? "Codex task")
            return ComposerTask(id:(task.composer ? "composer:" : "session:")+task.id,title:title,status:task.status,needsInput:task.needsInput)
        })
        surge.updateTasks(tasks)
    }
    private func returnFromSurge(_ notice: SurgeTaskStatus?) {
        if let notice, !notice.composer {
            scope="all"; search=""; refreshVisible(); selectSession(notice.id); tableFocused=true
        } else if let notice {
            model.send(["action":"composerSelect","key":notice.id]); composerPresented=true
        } else if model.hasActiveComposer { composerPresented=true }
        else {
            if let running = model.sessions.first(where: \.running) { scope="all"; search=""; refreshVisible(); selectSession(running.id) }
            tableFocused=true
        }
    }
    private func configureOnAppear() {
        if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--surge-preview") { surge.show() }
        if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--surge-intro-preview") { surge.show(intro:true) }

        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                if CommandLine.arguments.contains("--library-preview") || CommandLine.arguments.contains("--diagnostics-preview") {librarySettings=true}
                if CommandLine.arguments.contains("--reader-preview"),let item=model.sessions.first(where:{$0.id=="demo-0"}) {conversationTarget=ConversationTarget(id:item.id,title:item.title)}
                if CommandLine.arguments.contains("--search-preview") {search="animation pass"}
                if CommandLine.arguments.contains("--bulk-preview") {scope="all";refreshVisible();selectSession("demo-0");selectSession("demo-2",modifiers:.shift)}
                if CommandLine.arguments.contains("--activity-preview") {activityDate=Calendar.current.startOfDay(for:Date().addingTimeInterval(-86400))}
            }
        }
            columnSizes=(try? JSONDecoder().decode([String:Double].self,from:Data(savedWidths.utf8))) ?? [:]
            refreshVisible()
            if InteractionProbe.enabled {
                let bulkIDs:Set<String>=["demo-1","demo-2"]
                InteractionProbe.actions["bulkSelectRange"]={search="";scope="all";activityDate=nil;refreshVisible();selectSession("demo-1");selectSession("demo-2",modifiers:.shift)}
                InteractionProbe.values["bulkRangeSelected"]={selectedSessionIDs == bulkIDs}
                InteractionProbe.actions["bulkFavourite"]={model.perform(["action":"favouriteMany","ids":Array(bulkIDs),"favourite":true],undoManager:InteractionProbe.undoManager)}
                InteractionProbe.values["bulkFavourited"]={model.sessions.filter{bulkIDs.contains($0.id)}.allSatisfy{$0.favourite}}
                InteractionProbe.values["bulkUnfavourited"]={model.sessions.filter{bulkIDs.contains($0.id)}.allSatisfy{!$0.favourite}}
                InteractionProbe.actions["bulkAssign"]={model.perform(["action":"assignMany","assignments":Dictionary(uniqueKeysWithValues:bulkIDs.map{($0,"unassigned")})],undoManager:InteractionProbe.undoManager)}
                InteractionProbe.values["bulkAssigned"]={model.sessions.filter{bulkIDs.contains($0.id)}.allSatisfy{$0.project == "unassigned"}}
                InteractionProbe.values["bulkUnassigned"]={model.sessions.filter{bulkIDs.contains($0.id)}.allSatisfy{$0.project != "unassigned"}}
                InteractionProbe.actions["openAssistantSearch"]={search="ready for review"}
                InteractionProbe.values["assistantSearchHit"]={searchResultQuery == search && searchHits.contains{$0.role == "assistant" || $0.role == "Codex"}}
                InteractionProbe.actions["openSearchReader"]={if let hit=searchHits.first,let item=model.sessions.first(where:{$0.id == hit.threadID}) {conversationTarget=ConversationTarget(id:item.id,title:item.title,itemID:hit.itemID,query:search)}}
                InteractionProbe.values["conversationReaderOpen"]={conversationTarget != nil}
                InteractionProbe.actions["closeSearchReader"]={conversationTarget=nil;search=""}
                InteractionProbe.actions["filterActivityDay"]={search="";activityDate=Calendar.current.startOfDay(for:Date().addingTimeInterval(-86400));refreshVisible()}
                InteractionProbe.values["activityDayFiltered"]={activityDate != nil && !filtered.isEmpty && filtered.allSatisfy{s in SessionSelection.hasActivity(day:activityDate!,intervals:(model.activity[s.id] ?? []).map{($0.start,$0.end,$0.seconds)},running:s.running)}}
                InteractionProbe.actions["clearActivityDay"]={activityDate=nil;refreshVisible()}
                InteractionProbe.actions["reorderProjects"]={let ids=sortedProjects.map(\.id);if let last=ids.last,let first=ids.first {let value="navigator-projects:"+ProjectOrder.encode([last]);_ = drop([NSItemProvider(object:value as NSString)],to:first)}}
                InteractionProbe.actions["alphabeticalProjects"]={projectSort="Alphabetical"}
                InteractionProbe.actions["customProjects"]={projectSort="Custom"}
                InteractionProbe.values["customOrderSaved"]={projectSort == "Custom" && ProjectOrder.decode(NavigatorApp.preferences.string(forKey:"navigator.customProjectOrder") ?? "[]").first == sortedProjects.first?.id}
                InteractionProbe.values["customOrderRetained"]={!ProjectOrder.decode(customProjectOrder).isEmpty && projectSort == "Alphabetical"}
                InteractionProbe.values["customOrderRestored"]={projectSort == "Custom" && sortedProjects.first?.id == ProjectOrder.decode(customProjectOrder).first}
                InteractionProbe.actions["openComposer"]={openComposer()}
                InteractionProbe.actions["newProject"]={newProjectPresented=true}
                InteractionProbe.actions["newSession"]={newSessionPresented=true}
                InteractionProbe.values["newProjectSelected"]={project?.name == "Navigator Creation Check" && !newProjectPresented}
                InteractionProbe.values["newSessionProject"]={composerPresented && model.composer.project == scope.replacingOccurrences(of:"codex:",with:"") && model.composer.cwd == project?.path}
                InteractionProbe.values["inlineComposer"]={composerPresented}
                InteractionProbe.values["sessionsRestored"]={!composerPresented}
                InteractionProbe.actions["hideInspector"]={inspectorVisible=false}
                InteractionProbe.actions["showInspector"]={inspectorVisible=true}
                InteractionProbe.values["inspectorHidden"]={!inspectorVisible}
                InteractionProbe.values["inspectorShown"]={inspectorVisible}
                InteractionProbe.actions["unassigned"]={if let item=unassignedSessions.first {selectUnassigned(item.id)}}
                InteractionProbe.values["unassignedSelected"]={unassignedExpanded && session?.project == "unassigned"}
                InteractionProbe.actions["table"]={search="";refreshVisible();selected="demo-0";tableFocused=true}
                InteractionProbe.actions["search"]={search="";searchFocused=true}
                InteractionProbe.actions["filter"]={search="__no_matching_session__";refreshVisible()}
                InteractionProbe.actions["favourite"]={model.perform(["action":"preference","id":"demo-0","favourite":true],undoManager:InteractionProbe.undoManager)}
                InteractionProbe.values["favourited"]={model.sessions.first{$0.id=="demo-0"}?.favourite == true}
                InteractionProbe.values["unfavourited"]={model.sessions.first{$0.id=="demo-0"}?.favourite == false}
                InteractionProbe.values["sessionOpen"]={quickLook}
                InteractionProbe.values["sessionClosed"]={!quickLook}
                InteractionProbe.values["searchSpace"]={search==" "}
                InteractionProbe.values["movedSelection"]={selected != nil && selected != "demo-0"}
                InteractionProbe.values["selectionCleared"]={selected==nil && filtered.isEmpty}
            }
            if !accessSetupChecked {
                accessSetupChecked=true
                let demo=CommandLine.arguments.contains("--demo")
                if demo ? CommandLine.arguments.contains("--access-preview") : NavigatorApp.preferences.string(forKey:"navigator.previewAccess") == nil {
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {previewAccessSetup=true}
                }
            }
            appearance.setTheme(theme)
            if CommandLine.arguments.contains("--demo") { mode = "Overview"; theme = "Dark"; selected = "demo-0"; expanded = ["demo-0"] }
            if CommandLine.arguments.contains("--large-text") {textScale=1.5}
            if CommandLine.arguments.contains("--demo"),let i=CommandLine.arguments.firstIndex(of:"--text-scale"),CommandLine.arguments.count>i+1,let scale=Double(CommandLine.arguments[i+1]) {textScale=min(1.5,max(1,scale))}
            if CommandLine.arguments.contains("--light") {theme="Light"}
            if CommandLine.arguments.contains("--list") { mode = "List" }
            if CommandLine.arguments.contains("--overview") { mode = "Overview" }
            if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--narrow-chart") {
                sidebarWidth=380;inspectorWidth=650;activityHeight=230
            }
            if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--access-denied-preview") {NavigatorApp.preferences.set("denied",forKey:"navigator.previewAccess")}
            if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--group-preview") {
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {beginGrouping(Set(sortedProjects.prefix(2).map(\.id)),name:"Creative projects")}
            }
            if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--composer-approval-preview") {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {openComposer()}
                DispatchQueue.main.asyncAfter(deadline:.now()+1.5) {model.composerDraft="Review this project and suggest a focused improvement.";model.submitComposer()}
            }
            if CommandLine.arguments.contains("--demo"),let i=CommandLine.arguments.firstIndex(of:"--review-preview"),CommandLine.arguments.count>i+1 {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.8) {openComposer(target:sortedProjects.first)}
                DispatchQueue.main.asyncAfter(deadline:.now()+1.8) {
                    if let text=try? String(contentsOfFile:CommandLine.arguments[i+1]) {
                        model.composer.status="completed"
                        model.composer.messages=[ComposerMessage(id:"review-request",role:"You",text:"Quick Prompt: Evaluate Design"),ComposerMessage(id:"review-result",role:"Codex",text:text)]
                    }
                }
            }
            if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--new-project-preview") {
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {newProjectPresented=true}
            }
            if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--attachments-preview") {
                DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                    if let path=Bundle.main.path(forResource:"demo-preview",ofType:"png"),let attachment=try? ComposerAttachmentImport.local(URL(fileURLWithPath:path)) {
                        model.composerStore.addAttachments([attachment],to:model.composer.taskKey ?? "")
                        model.composerDraft="Compare this reference and suggest improvements."
                    }
                }
            }
            if CommandLine.arguments.contains("--demo") && (CommandLine.arguments.contains("--composer-preview") || CommandLine.arguments.contains("--attachments-preview") || CommandLine.arguments.contains("--session-preview")) {
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {openComposer(target:sortedProjects.first)}
            }
            if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--session-preview") {
                DispatchQueue.main.asyncAfter(deadline:.now()+2.5) {
                    model.composer.status="completed";model.composer.active=false
                    model.composer.messages=[
                        ComposerMessage(id:"session-user",role:"You",text:"Show the thinking and work history in this conversation."),
                        ComposerMessage(id:"session-thought",role:"Thinking",text:"Checking the session events and preserving the work history."),
                        ComposerMessage(id:"session-progress",role:"Codex",text:"I’m checking the available session controls.",phase:"commentary"),
                        ComposerMessage(id:"session-command",role:"Command",text:"Run session checks\nAll checks passed."),
                        ComposerMessage(id:"session-work",role:"Work",text:"",durationSeconds:94),
                        ComposerMessage(id:"session-final",role:"Codex",text:"The session now includes expandable thinking summaries, work history, and voice controls.",phase:"final_answer")
                    ]
                }
            }
            if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--unassigned-preview") {
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {unassignedExpanded=true;scope="unassigned"}
            }
            if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--voice-preview") {
                DispatchQueue.main.asyncAfter(deadline:.now()+1) {selected="demo-7";quickLook=true}
            }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button("Codex Navigator") { scope="all"; selectedProjects=[]; mode="Overview"; selected=nil; selectedSessionIDs=[]; activityDate=nil; expanded=[]; search=""; days=0; minimumDuration=0; mediaOnly=false; runningOnly=false; sessionType="All types" }.font(.system(size:16*textScale,weight:.semibold)).padding(.leading,40)
            Spacer(minLength: 20)
            Picker("Theme",selection: $theme) { ForEach(["System","Light","Dark"],id: \.self) { Text($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
            Button {showOptions.toggle()} label: {Image(systemName:"slider.horizontal.3")}.help("View options")
                .popover(isPresented: $showOptions) {
                    VStack(alignment: .leading,spacing: 14) {
                        Text("View Options").font(.headline)
                        HStack {Text("Text size");Slider(value:$textScale,in:1...1.5,step:0.05);Text("\(Int(textScale*100))%").monospacedDigit()}
                        Picker("Density",selection:$density) {Text("Comfortable").tag("Comfortable");Text("Compact").tag("Compact")}
                        Picker("Sort by",selection: $sort) {ForEach(["Name"] + allColumns,id: \.self) {Text(columnLabel($0)).tag($0)}}
                        Toggle("Descending",isOn: $descending)
                        Divider()
                        Text("Columns · drag headers to reorder").font(.system(size:12*textScale))
                        ForEach(allColumns,id:\.self) { name in
                            Toggle(columnLabel(name),isOn:Binding(get:{columns.contains(name)},set:{show in
                                var values=columns; values.removeAll {$0 == name}; if show {values.append(name)}; columnOrder=values.joined(separator:"|")
                            }))
                        }
                        Button("File access for previews…") {showOptions=false;previewAccessSetup=true}
                        Button("Reset columns") {columnOrder="Modified|Active time|Size|Media";savedWidths="{}";columnSizes=[:];nameFillsSpace=true}
                        Divider()
                        Button("Organise voice chats…") {showOptions=false;voiceOrganizer=true}
                        Button("Library & diagnostics…") {showOptions=false;librarySettings=true}
                        Text("Overview includes activity and preview. List fills the browser with sessions.").font(.system(size:12*textScale)).foregroundStyle(.secondary)
                    }.padding(20).frame(width: 270)
                }
            Picker("View",selection: $mode) { Text("Overview").tag("Overview"); Text("List").tag("List") }
                .pickerStyle(.segmented).labelsHidden().frame(width: 158)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search sessions",text: $search).textFieldStyle(.plain).focused($searchFocused) }
                .padding(7).background(.quaternary.opacity(0.5),in: RoundedRectangle(cornerRadius: 7)).frame(width: 230)
            ComposerToolbarButton(store:model.composerStore) {model.send(["action":"composerGet"]);composerPresented=true}
            Button {inspectorVisible.toggle();if inspectorVisible {mode="Overview"}} label: {Image(systemName:"sidebar.right")}.help(inspectorVisible ? "Hide right panel" : "Show right panel")
            Button {model.reconnectIndex()} label: {Image(systemName:"arrow.clockwise")}.help("Refresh index")
        }.buttonStyle(.borderless).padding(.horizontal,16).frame(height:58)
        .background(WindowDragArea())

    }

    private var projectSections:[ProjectSection] {
        let projects=sortedProjects
        if projectSort != "Custom" {
            return projects.filter{$0.group.isEmpty}.map{ProjectSection(id:$0.id,name:"",projects:[$0])} +
                Array(Set(projects.map(\.group).filter{!$0.isEmpty})).sorted().map{name in ProjectSection(id:"group:"+name,name:name,projects:projects.filter{$0.group == name})}
        }
        var sections:[ProjectSection]=[]
        for project in projects {
            if !project.group.isEmpty,let index=sections.firstIndex(where:{$0.name == project.group}) {sections[index].projects.append(project)}
            else {sections.append(ProjectSection(id:project.group.isEmpty ? project.id : "group:"+project.group,name:project.group,projects:[project]))}
        }
        return sections
    }
    private var sidebar: some View {
        VStack(alignment: .leading,spacing: 5) {
            Menu {
                Button("New Project",systemImage:"folder.badge.plus") {newProjectPresented=true}
                Button("New Session",systemImage:"square.and.pencil") {newSessionPresented=true}
            } label: {
                Label("New",systemImage:"plus").font(.system(size:16*textScale,weight:.medium))
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,9)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal:false,vertical:true)
            nav("All Sessions",icon:"tray.full",key:"all")
            nav("Recent",icon:"clock",key:"recent")
            nav("Favourites",icon:"star",key:"favourites")
            nav("Archived",icon:"archivebox",key:"archived")
            Picker("Projects",selection:$projectSort) {ForEach(["Alphabetical","Last updated","Biggest","Custom"],id:\.self) {Text($0 == "Biggest" ? "Largest history" : $0).tag($0)}}.font(.system(size:12*textScale)).padding(.top,16)
            Text("PROJECTS").font(.system(size:12*textScale,weight: .semibold)).foregroundStyle(.secondary).padding(.top,25).padding(.horizontal,12)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(projectSections) {section in
                        if section.name.isEmpty {
                            ForEach(section.projects) {p in projectRow(p)}
                        } else {
                            DisclosureGroup(section.name) {
                                ForEach(section.projects) {p in projectRow(p)}
                            }.padding(.horizontal,6)
                            .onDrop(of:[UTType.text],isTargeted:nil) {drop($0,toGroup:section.name)}
                        }
                    }
                    Text("Drop to move to end").font(.system(size:12*textScale)).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.vertical,8)
                        .onDrop(of:[UTType.text],isTargeted:nil) {drop($0,to:"__custom_end__")}
                    Divider().padding(.vertical,10)
                    DisclosureGroup(isExpanded:$unassignedExpanded) {
                        ForEach(unassignedSessions) {item in
                            Button {selectUnassigned(item.id)} label: {
                                HStack(spacing:8) {Image(systemName:"doc.text");Text(item.title).lineLimit(2);Spacer(minLength:0)}
                                    .font(.system(size:13*textScale)).padding(8).frame(maxWidth:.infinity,alignment:.leading)
                                    .background(selected == item.id && scope == "unassigned" ? Color.accentColor.opacity(0.23) : .clear,in:RoundedRectangle(cornerRadius:6))
                            }.buttonStyle(.plain).padding(.leading,22).help(item.title)
                            .onDrag {NSItemProvider(object:("navigator-session:"+item.id) as NSString)}
                        }
                        if unassignedSessions.isEmpty {Text("No unassigned sessions").foregroundStyle(.secondary).padding(8)}
                    } label: {
                        nav("Unassigned (\(unassignedSessions.count))",icon:"tray",key:"unassigned")
                    }
                    .onDrop(of:[UTType.text],isTargeted: Binding(get:{dropTarget == "unassigned"},set:{dropTarget = $0 ? "unassigned" : nil})) {drop($0,to:"unassigned")}

                }
            }
            Spacer(minLength: 0)
            HStack(spacing:8) {Image(systemName:"internaldrive");Text("History across accounts")}.font(.system(size:12*textScale)).foregroundStyle(.secondary).padding(12).help("One local library across Codex sign-ins in this macOS user profile. Switching accounts keeps your work easy to find; this is not cloud sync.")
        }.padding(10).background(.ultraThinMaterial)
    }
    private var unassignedSessions:[Session] {model.sessions.filter{$0.project == "unassigned" && !$0.archived}.sorted{$0.modified>$1.modified}}
    private func selectUnassigned(_ id:String) {
        search="";days=0;minimumDuration=0;mediaOnly=false;runningOnly=false;sessionType="All types";activityDate=nil
        selectedProjects=[];unassignedExpanded=true
        if scope != "unassigned" {sidebarSelection=id;scope="unassigned"}
        else {refreshVisible();selected=id}
    }
    @StoredState private var hoveredProjectID:String?=nil
    private func projectRow(_ p:Project) -> some View {
        HStack(spacing:10) {
            ProjectIcon(project:p,size:22)
            Text(p.name).lineLimit(1)
            if ProjectLauncher.status(for:p) == .running {Image(systemName:"play.circle.fill").foregroundStyle(.green).help("Project launched in Navigator")}
            if p.pinned {Image(systemName:"pin.fill").font(.system(size:12*textScale)).foregroundStyle(.secondary)}
            Spacer(minLength:0)
            if model.projectStats[p.id]?.running == true {Circle().fill(.green).frame(width:6,height:6)}
        }.padding(.leading,28).padding(.horizontal,10).frame(height:36)
        .background(selectedProjects.contains(p.id) ? Color.accentColor.opacity(0.23) : Color.clear,in:RoundedRectangle(cornerRadius:7))
        .overlay(alignment:.top) {if dropTarget == p.id && draggingProjects {Rectangle().fill(Color.accentColor).frame(height:2)}}
        .overlay(RoundedRectangle(cornerRadius:7).stroke(dropTarget == p.id && !draggingProjects ? Color.accentColor : .clear,lineWidth:2))
        .overlay(ProjectDragSurface(id:p.id,name:p.name,payload:{
            let ids=selectedProjects.contains(p.id) ? selectedProjects : [p.id]
            return "navigator-projects:"+ProjectOrder.encode(Array(ids))
        },click:{
            if NSEvent.modifierFlags.contains(.command) {
                if selectedProjects.contains(p.id) {selectedProjects.remove(p.id)} else {selectedProjects.insert(p.id)}
            } else {selectedProjects=[p.id]}
            scope=p.id
        },dragging:{draggingProjects=$0},targeted:{dropTarget=$0 ? p.id : nil},drop:{value in
            drop([NSItemProvider(object:value as NSString)],to:p.id)
        }).padding(.leading,34))
        .overlay(alignment:.leading) {
            Button {openComposer(target:p)} label: {
                Image(systemName:"square.and.pencil")
                    .font(.system(size:15*textScale))
                    .frame(width:24,height:36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New task in " + p.name)
            .accessibilityLabel("New task in " + p.name)
            .opacity(hoveredProjectID == p.id ? 1 : 0)
            .allowsHitTesting(hoveredProjectID == p.id)
            .padding(.leading,6)
        }
        .onHover {inside in
            if inside {hoveredProjectID=p.id}
            else if hoveredProjectID == p.id {hoveredProjectID=nil}
        }
        .contextMenu {projectMenu(p)}
        .help("Drag to place before another project. Custom order is saved in Navigator. Use the menu to group projects.")
        .id(p.id + ":launch:" + String(launchRevision))
    }
    private func nav(_ label:String,icon:String,key:String) -> some View {
        Button {scope = key;selectedProjects=[]} label: {
            HStack(spacing: 12) {Image(systemName:icon).font(.system(size:17*textScale)).frame(width:22);Text(label);Spacer()}
                .padding(.horizontal,10).frame(height:36)
                .background(scope == key ? Color.accentColor.opacity(0.23) : .clear,in:RoundedRectangle(cornerRadius:7))
                .overlay(RoundedRectangle(cornerRadius:7).stroke(dropTarget == key ? Color.accentColor : .clear,lineWidth:2))
        }.buttonStyle(.plain)
    }
    private func projectMenu(_ p:Project) -> some View {
        Group {
            Button("New Task") {openComposer(target:p)}
            if let label=ProjectLauncher.launchLabel(for:p) {Text("Launch: " + label)}
            if ProjectLauncher.status(for:p) != .idle {Text("Launch status: " + ProjectLauncher.status(for:p).description)}
            Button("Launch Project") {ProjectLauncher.launchLatest(project:p) {model.error=$0}}
                .disabled(p.path.isEmpty)
            Button("Launch setup…") {ProjectLauncher.configure(project:p) {model.error=$0}}
            Button("Stop launched process") {ProjectLauncher.stop(project:p)}.disabled(ProjectLauncher.status(for:p) != .running)
            if ProjectLauncher.launchCommand(for:p) != nil {Button("Copy launch command") {_ = ProjectLauncher.copyLaunchCommand(for:p)}}
            Button("Show launch log") {ProjectLauncher.showLog(project:p) {model.error=$0}}
            Button("Choose launch target…") {ProjectLauncher.choose(project:p) {model.error=$0}}
            Divider()
            Button("Logo & appearance…") {logoProject=p}
            Button(p.pinned ? "Unpin in Navigator" : "Pin in Navigator") {model.send(["action":"preference","id":p.id,"pinned":!p.pinned])}.disabled(p.codexPinned)
            if p.codexPinned {Text("Pinned in Codex")}
            Button("Group projects…") {beginGrouping(selectedProjects.contains(p.id) ? selectedProjects : [p.id],name:p.group)}
            if !p.group.isEmpty {
                Button("Remove from group") {model.send(["action":"groupProjects","ids":Array(selectedProjects.contains(p.id) ? selectedProjects : [p.id]),"name":""])}
            }
            if !p.path.isEmpty {Button("Reveal in Finder") {NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:p.path)])}}
            Menu("Folder colour") {ForEach(["blue","green","purple","orange","red","grey"],id:\.self) {colour in
                Button(colour.capitalized) {model.send(["action":"preference","id":p.id,"colour":colour])}
            }}
        }
    }

    @AppStorage("navigator.showActivity") private var showActivity=true
    private func overviewHeader(maxHeight:Double) -> some View {
        VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.top,spacing:16) {
                if let p=project {ProjectIcon(project:p,size:42,overview:true)} else {Image(systemName:scope == "unassigned" ? "tray.fill" : "folder.fill").font(.system(size:28*textScale)).foregroundStyle(.blue)}
                VStack(alignment:.leading,spacing:4) {
                    HStack {Text(title).font(.system(size:20*textScale,weight:.semibold));if let p=project {Menu {projectMenu(p)} label: {Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).frame(width:22)}}
                    if let p=project {PathLink(path:p.path).font(.system(size:12*textScale)).lineLimit(1)}
                    Text("\(filtered.count) \(filtered.count == 1 ? "session" : "sessions") · \((filtered.contains{$0.runtimeCoverage != "complete"} ? "≥ " : "") + durationText(filtered.reduce(0){$0+$1.duration(at:Date())})) indexed active time").font(.system(size:12*textScale)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            DisclosureGroup("Activity · recognise when you worked",isExpanded:$showActivity) {
            Group {
                if filtered.contains(where:{$0.running}) {
                    TimelineView(.periodic(from:.now,by:30)) {ctx in ActivityChart(sessions:computeFiltered(ignoreActivity:true),activity:model.activity,now:ctx.date,selectedDay:activityDate,onSelect:{activityDate=$0})}
                } else {ActivityChart(sessions:computeFiltered(ignoreActivity:true),activity:model.activity,selectedDay:activityDate,onSelect:{activityDate=$0})}
            }.frame(height:min(activityHeight,maxHeight)).padding(.top,8)
            }.font(.system(size:12*textScale))
        }.padding(.horizontal,20).padding(.top,12).padding(.bottom,10)
    }

    private var dateFilter:some View {
        Picker("Modified",selection:$days) {Text("Any date").tag(0);Text("Last hour").tag(1);Text("Last 3 hours").tag(3);Text("Last 6 hours").tag(6);Text("Last 12 hours").tag(12);Text("1 day").tag(24);Text("3 days").tag(72);Text("1 week").tag(168);Text("1 month").tag(720)}
    }
    private var durationFilter:some View {
        Picker("Duration",selection:$minimumDuration) {Text("Any duration").tag(0);Text("Over 1 hour").tag(3600);Text("Over 8 hours").tag(28800)}
    }
    private var typeFilter:some View {Picker("Type",selection:$sessionType) {Text("All types").tag("All types");Text("Codex").tag("Codex")}}
    private var filterSummary:String {
        var labels:[String]=[]
        if days>0 {labels.append([1:"Last hour",3:"Last 3 hours",6:"Last 6 hours",12:"Last 12 hours",24:"1 day",72:"3 days",168:"1 week",720:"1 month"][days] ?? "Last \(days) hours")}
        if minimumDuration>0 {labels.append(minimumDuration == 3600 ? "Over 1 hour" : "Over 8 hours")}
        if sessionType != "All types" {labels.append(sessionType)}
        if mediaOnly {labels.append("Has assets")}
        if runningOnly {labels.append("Running")}
        return labels.isEmpty ? "Filters" : labels.joined(separator:" · ")
    }
    private func clearFilters() {activityDate=nil;search="";days=0;minimumDuration=0;mediaOnly=false;runningOnly=false;sessionType="All types";refreshVisible()}
    private var filters:some View {
        HStack(spacing:12) {
            if mode == "List" {Text(title).font(.headline).lineLimit(1)}
            ViewThatFits(in:.horizontal) {
                HStack(spacing:10) {
                    dateFilter.labelsHidden().frame(width:115*textScale)
                    durationFilter.labelsHidden().frame(width:125*textScale)
                    typeFilter.labelsHidden().frame(width:95*textScale)
                    Toggle("Has assets",isOn:$mediaOnly).toggleStyle(.checkbox)
                    Toggle("Running",isOn:$runningOnly).toggleStyle(.checkbox)
                }.fixedSize()
                Menu {
                    dateFilter;durationFilter;typeFilter
                    Toggle("Has assets",isOn:$mediaOnly);Toggle("Running",isOn:$runningOnly)
                    Divider();Button("Clear filters") {clearFilters()}
                } label: {Label(filterSummary,systemImage:"line.3.horizontal.decrease.circle")}
            }
            Spacer(minLength:0)
            newMenu
        }.font(.system(size:13*textScale)).padding(.horizontal,16).padding(.vertical,12)
    }

    @ViewBuilder private var contextualBar:some View {
        if let day=activityDate {
            HStack {
                Label("Activity on " + day.formatted(date:.abbreviated,time:.omitted),systemImage:"calendar").lineLimit(1)
                Button {activityDate=nil} label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).help("Clear activity date")
                Spacer()
            }.font(.system(size:12*textScale)).foregroundStyle(Color.accentColor).padding(.horizontal,18).padding(.bottom,10)
        }
        if selectedSessionIDs.count>1 {
            HStack(spacing:12) {
                Text("\(selectedSessionIDs.count) selected").fontWeight(.semibold)
                Menu("Favourite") {
                    Button("Add to favourites") {model.send(["action":"favouriteMany","ids":Array(selectedSessionIDs),"favourite":true])}
                    Button("Remove from favourites") {model.send(["action":"favouriteMany","ids":Array(selectedSessionIDs),"favourite":false])}
                }.fixedSize()
                Menu("Assign") {
                    Button("Unassigned") {assignSessions(Array(selectedSessionIDs),to:"unassigned")}
                    ForEach(model.projects) {p in Button(p.name) {assignSessions(Array(selectedSessionIDs),to:p.id)}}
                }.fixedSize()
                Spacer(minLength:0)
                Button {selectedSessionIDs=selected.map{[$0]} ?? []} label:{Image(systemName:"xmark.circle")}.help("Clear multiple selection")
            }.font(.system(size:12*textScale)).padding(.horizontal,18).padding(.vertical,9).background(Color.accentColor.opacity(0.08))
        }
        if !search.isEmpty {
            HStack(spacing:8) {
                if searchLoading {ProgressView().controlSize(.mini)}
                Text(searchFailure ?? (searchTruncated ? "Showing the first 200 matching passages. Refine your search for more." : searchIncomplete ? "Searching available history · some conversations are still indexing" : "Search includes your requests and Codex responses"))
                    .lineLimit(2)
                Spacer(minLength:0)
            }.font(.system(size:11*textScale)).foregroundStyle(.secondary).padding(.horizontal,18).padding(.bottom,8)
        }
    }
    private func findPassages() {
        searchGeneration+=1;let generation=searchGeneration
        let query=search
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {searchHits=[];searchResultQuery="";searchLoading=false;searchFailure=nil;return}
        searchLoading=true;searchFailure=nil
        model.request(["action":"search","query":query,"limit":200],as:SearchResponse.self) {result in
            guard generation==searchGeneration,query==search else {return}
            searchLoading=false
            switch result {
            case .success(let value):searchHits=value.results;searchResultQuery=query;searchIncomplete = !value.complete;searchTruncated=value.truncated ?? false;refreshVisible()
            case .failure:searchFailure="Passage search is unavailable. Showing matches in cached session summaries."
            }
        }
    }
    private func actionIDs(_ clicked:String)->[String] {selectedSessionIDs.contains(clicked) ? filtered.map(\.id).filter{selectedSessionIDs.contains($0)} : [clicked]}
    private func assignSessions(_ ids:[String],to project:String) {
        model.send(["action":"assignMany","assignments":Dictionary(ids.map{($0,project)},uniquingKeysWith:{a,_ in a})])
    }
    private func selectSession(_ id:String,modifiers:NSEvent.ModifierFlags=[]) {
        selectedSessionIDs=SessionSelection.select(id,visible:filtered.map(\.id),selected:selectedSessionIDs,anchor:sessionAnchor,extending:modifiers.contains(.shift),toggling:modifiers.contains(.command))
        if !modifiers.contains(.shift) {sessionAnchor=id}
        selected=selectedSessionIDs.contains(id) ? id : filtered.last(where:{selectedSessionIDs.contains($0.id)})?.id
        tableFocused=true
    }

    private var table: some View {
        GeometryReader { geometry in
        let availableWidth=max(tableWidth,geometry.size.width)
        let nameWidth=nameFillsSpace ? availableWidth-columns.reduce(0){$0+width($1)}-36 : width("Name")
        ScrollView(.horizontal) { VStack(spacing:0) {
            Divider()
            HStack(spacing:0) {
                column("Name",width:nameWidth)
                ForEach(columns,id:\.self) {name in column(name,width:width(name))}
                Spacer(minLength:0)
            }.padding(.horizontal,18).frame(height:33).zIndex(2)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No sessions here" : "No matching sessions",systemImage:"tray",description:Text(model.sessions.isEmpty ? "Your local history will appear as the index connects." : "Change the filters or refresh your local history."))
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
                Button("Clear filters") {clearFilters()}.padding()
            } else {
                ScrollViewReader {proxy in ScrollView {
                    LazyVStack(spacing:0) {ForEach(filtered) {s in sessionRow(s,nameWidth:nameWidth,previewWidth:geometry.size.width).id(s.id).onAppear {appearedRows.insert(s.id)}.onDisappear {appearedRows.remove(s.id)}}}.padding(.horizontal,8).padding(.top,5)
                }.onChange(of:selected) {_,id in if let id {proxy.scrollTo(id)}}
                }
            }
        }.frame(width:availableWidth,height:geometry.size.height)
        }}
    }
    private func column(_ name:String,width columnWidth:CGFloat?) -> some View {
        HStack(spacing:0) {
            Button {
                if sort == name {descending.toggle()} else {sort=name;descending=name != "Name"}
            } label: {
                HStack(spacing:5) {Text(columnLabel(name));if sort == name {Image(systemName:descending ? "arrow.down" : "arrow.up")};Spacer(minLength:0)}
                    .padding(.leading,name == "Name" ? 0 : 8).padding(.trailing,8).contentShape(Rectangle())
            }.buttonStyle(.plain).font(.system(size:13*textScale,weight:.medium)).foregroundStyle(.secondary)
                .frame(maxWidth:.infinity,alignment:.leading)
                .onDrag {draggingColumn=name;return NSItemProvider(item:Data(name.utf8) as NSData,typeIdentifier:"local.navigator.column")}
        .onDrop(of:["local.navigator.column"],isTargeted:nil) { providers in
            guard let from=draggingColumn, from != "Name", name != "Name", let start=columns.firstIndex(of:from),let end=columns.firstIndex(of:name) else {return false}
            var values=columns;values.remove(at:start);values.insert(from,at:end);columnOrder=values.joined(separator:"|");draggingColumn=nil;return true
        }
            ResizeHandle(value:Binding(get:{columnWidth ?? width(name)},set:{newWidth in
                if name == "Name" {nameFillsSpace=false}
                columnSizes[name]=newWidth
            }),limits:(name == "Name" ? 170.0 : (name == "Media" ? 65.0 : 110.0)*textScale)...1200.0,vertical:false,direction:1,label:name+" column width",onCommit:{if let data=try? JSONEncoder().encode(columnSizes),let text=String(data:data,encoding:.utf8) {savedWidths=text}})
                .frame(width:14,height:28)
        }.frame(width:columnWidth)

    }
    private func sessionRow(_ s:Session,nameWidth:CGFloat,previewWidth:CGFloat) -> some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:0) {
                HStack(spacing:9) {
                    Button {if expanded.contains(s.id) {expanded.remove(s.id)} else {expanded.insert(s.id)};selected=s.id} label: {Image(systemName:expanded.contains(s.id) ? "chevron.down" : "chevron.right").font(.system(size:12*textScale,weight:.semibold)).frame(width:16,height:24)}.buttonStyle(.plain).help("Expand user prompts")
                    Image(systemName:s.running ? "circle.inset.filled" : s.title.localizedCaseInsensitiveContains("voice") ? "waveform" : s.sessionType == "Chat" ? "bubble.left" : s.sessionType == "Work" ? "briefcase" : "doc.text").foregroundStyle(s.running ? Color.green : (selectedSessionIDs.contains(s.id) && tableFocused ? .white : .secondary))
                    VStack(alignment:.leading,spacing:2) {
                        Text(s.title).lineLimit(1).help(s.title)
                        if s.running || s.sync == "Navigator only" || s.sync == "Conflict" || s.status == "Status stale" {
                            Text(s.running ? "Running · updating live" : s.status == "Status stale" ? "Status stale" : s.sync).font(.system(size:12*textScale)).opacity(0.8)
                        }
                    }
                    if s.favourite {Image(systemName:"star.fill").font(.system(size:12*textScale)).foregroundStyle(.yellow)}
                    Spacer(minLength:4)
                }.frame(width:nameWidth,alignment:.leading)
                ForEach(columns,id:\.self) {name in
                    Group {
                        if name == "Active time" && s.running {
                            TimelineView(.periodic(from:.now,by:1)) {context in Text(cell(s,name,at:context.date))}
                        } else {Text(cell(s,name,at:Date()))}
                    }.lineLimit(1).frame(width:width(name),alignment:.leading).monospacedDigit()
                        .help(name == "Size" ? "Size of the local rollout file; excludes external media." : cell(s,name,at:Date()))
                }
                Spacer(minLength:0)
            }.font(.system(size:14*textScale)).padding(.horizontal,10).frame(height:(density == "Compact" ? 38 : 48)*textScale)
                .foregroundStyle(selectedSessionIDs.contains(s.id) && tableFocused ? .white : .primary)
                .background(selectedSessionIDs.contains(s.id) ? tableFocused ? Color.accentColor : Color.accentColor.opacity(0.18) : Color.clear,in:RoundedRectangle(cornerRadius:6))
                .contentShape(Rectangle())
                .accessibilityElement(children:.combine)
                .accessibilityAddTraits(selectedSessionIDs.contains(s.id) ? [.isSelected] : [])
                .onTapGesture(count:2) {openComposer(session:s)}
                .onTapGesture {selectSession(s.id,modifiers:NSEvent.modifierFlags)}
                .onDrag {
                    draggingProjects=false
                    if !selectedSessionIDs.contains(s.id) {selectSession(s.id)}
                    let ids=filtered.map(\.id).filter{selectedSessionIDs.contains($0)}
                    return NSItemProvider(object:("navigator-sessions:"+ProjectOrder.encode(ids)) as NSString)
                }
                .contextMenu {
                    Button("Continue in Navigator") {openComposer(session:s)}
            Button("Open in Codex") {model.open(s.id)}
                    Button("Read conversation") {conversationTarget=ConversationTarget(id:s.id,title:s.title)}
                    Button("Quick Look") {selected=s.id;quickLook=true}
                    Button(actionIDs(s.id).count>1 ? "Favourite selected sessions" : s.favourite ? "Remove favourite" : "Favourite") {model.send(["action":"favouriteMany","ids":actionIDs(s.id),"favourite":actionIDs(s.id).count>1 || !s.favourite])}
                    if actionIDs(s.id).count>1 {Button("Remove selected favourites") {model.send(["action":"favouriteMany","ids":actionIDs(s.id),"favourite":false])}}
                    Button("Rename…") {selected=s.id;rename=true}
                    Menu("Assign in Navigator") {
                        Button("Unassigned") {assignSessions(actionIDs(s.id),to:"unassigned")}
                        ForEach(model.projects) {p in Button(p.name) {assignSessions(actionIDs(s.id),to:p.id)}}
                    }
                    if s.project != s.nativeProject {Button("Use Codex location") {model.send(["action":"restore","id":s.id])}}
                }
            if !search.isEmpty,searchResultQuery == search,let hit=searchHits.first(where:{$0.threadID == s.id}) {
                Button {conversationTarget=ConversationTarget(id:s.id,title:s.title,itemID:hit.itemID,query:search)} label: {
                    HStack(alignment:.top,spacing:8) {
                        Text(hit.role == "user" ? "You" : "Codex").fontWeight(.semibold)
                        HighlightedSnippet(text:hit.snippet,query:search).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength:0);Image(systemName:"arrow.up.right")
                    }.font(.system(size:12*textScale)).foregroundStyle(.secondary).padding(.vertical,7).padding(.leading,36).padding(.trailing,18)
                        .frame(width:previewWidth,alignment:.leading)
                }.buttonStyle(.plain).help("Read the matching passage")
            }
            if expanded.contains(s.id) {prompts(s,available:previewWidth)}
            Divider().padding(.leading,34)
        }
    }
    private func prompts(_ s:Session,available:CGFloat) -> some View {
        let list=model.details[s.id]?.prompts ?? []
        let ordered=reversed.contains(s.id) ? Array(list.reversed()) : list
        return LazyVStack(alignment:.leading,spacing:10) {
            Menu {
                Button {reversed.remove(s.id)} label: {Label("First to Last",systemImage:reversed.contains(s.id) ? "" : "checkmark")}
                Button {reversed.insert(s.id)} label: {Label("Last to First",systemImage:reversed.contains(s.id) ? "checkmark" : "")}
            } label: {Text("User prompts (\(s.promptCount)) ↕").font(.system(size:13*textScale,weight:.semibold))}
                .menuStyle(.borderlessButton).fixedSize().help("Order user prompts")
            if ordered.isEmpty {Text(s.indexed ? "No user prompts in the available history." : "Loading prompt history…").font(.system(size:12*textScale)).foregroundStyle(.secondary)}
            ForEach(Array(ordered.prefix(promptLimits[s.id] ?? 50))) {p in
                HStack(alignment:.top,spacing:12) {
                    Text("•")
                    Text(p.time > 0 ? Date(timeIntervalSince1970:p.time).formatted(.dateTime.day().month(.abbreviated).hour().minute()) : "Unknown time").foregroundStyle(.secondary).frame(width:100*textScale,alignment:.leading)
                    LinkedText(text:p.text).frame(maxWidth:.infinity,alignment:.leading)
                }.font(.system(size:13*textScale))
            }
            if ordered.count>(promptLimits[s.id] ?? 50) {Button("Show next 50 prompts") {promptLimits[s.id]=(promptLimits[s.id] ?? 50)+50}}
            if !s.indexError.isEmpty {Text(s.indexError).font(.system(size:12*textScale)).foregroundStyle(.orange)}
        }.frame(width:max(200,available-82),alignment:.leading).padding(.leading,48).padding(.trailing,18).padding(.vertical,15)
            .background(.quaternary.opacity(0.16))
    }

    private var inspectorSession: Session? {
        let id=SessionSelection.inspectorID(selected:selected,composerPresented:composerPresented,threadID:inspectorComposer.threadId)
        return model.sessions.first {$0.id == id}
    }

    private var inspector: some View {
        VStack(alignment:.leading,spacing:0) {
            if let s=inspectorSession {
                ScrollViewReader {proxy in ScrollView {
                    VStack(alignment:.leading,spacing:19) {
                        HStack(alignment:.top) {
                            Text(s.title).font(.system(size:19*textScale,weight:.semibold)).textSelection(.enabled)
                            Spacer(minLength:0)
                            Button {model.send(["action":"preference","id":s.id,"favourite":!s.favourite])} label: {Image(systemName:s.favourite ? "star.fill" : "star").foregroundStyle(.yellow)}.buttonStyle(.plain)
                        }
                        Label(model.projectName(s.project),systemImage:s.project == "unassigned" ? "tray" : "folder.fill").font(.system(size:12*textScale)).foregroundStyle(.secondary)
                        Divider()
                        Text("Resume").font(.system(size:14*textScale,weight:.semibold))
                        Label(s.status,systemImage:s.running ? "play.circle" : "clock").font(.system(size:12*textScale)).foregroundStyle(.secondary)
                        Text("Latest request").font(.system(size:12*textScale,weight:.medium)).foregroundStyle(.secondary)
                        LinkedText(text:model.details[s.id]?.prompts.last?.text ?? (model.details[s.id] == nil ? "Loading latest request…" : "No request available.")).font(.system(size:14*textScale)).lineLimit(4)
                        if let detail=model.details[s.id],!detail.lastResponse.isEmpty {
                            Text("Latest response").font(.system(size:12*textScale,weight:.medium)).foregroundStyle(.secondary)
                            LinkedText(text:detail.lastResponse).font(.system(size:14*textScale)).lineLimit(5)
                        }
                        DisclosureGroup("Original request") {
                        LinkedText(text:model.details[s.id]?.prompts.first?.text ?? (model.details[s.id] == nil ? "Loading preview…" : s.indexed ? "No request available." : "Indexing history…")).font(.system(size:14*textScale)).foregroundStyle(.primary).lineLimit(5).textSelection(.enabled)
                        }
                        Divider()
                        Text("Media · " + countText(s.mediaCount,"asset")).font(.system(size:14*textScale,weight:.semibold))
                        mediaGrid(s,reveal:{proxy.scrollTo($0)})
                        Divider()
                        DisclosureGroup("Session details",isExpanded:$metadataExpanded) {
                        VStack(spacing:11) {
                            info("Status",s.status)
                            Group {if s.running {TimelineView(.periodic(from:.now,by:1)) {ctx in info("Active time",s.durationLabel(at:ctx.date))}} else {info("Active time",s.durationLabel(at:Date()))}}
                            info("Session span",durationText(s.modified-s.created))
                            info("Modified",dateText(s.modified))
                            info("Created",dateText(s.created))
                            info("Prompts",s.indexed ? "\(s.promptCount)" : "Indexing…")
                            info("Token usage",s.tokenUsage.map {$0.formatted()} ?? "Unavailable")
                            info("Messages",s.indexed ? "\(s.messages)" : "Indexing…")
                            info("Files changed",s.indexed ? "\(s.filesChanged)" : "—")
                            info("Source",s.source)
                        }
                        Divider()
                        VStack(alignment:.leading,spacing:8) {
                            Label(s.sync,systemImage:s.sync == "Conflict" ? "exclamationmark.arrow.triangle.2.circlepath" : "folder.badge.gearshape").font(.system(size:14*textScale,weight:.medium)).foregroundStyle(s.sync == "Conflict" ? .orange : .secondary)
                            Text("Navigator: \(model.projectName(s.project))").font(.system(size:12*textScale))
                            PathLink(path:s.cwd).font(.system(size:12*textScale))
                            if s.project != s.nativeProject {
                                Text("This assignment is saved in Navigator. Codex’s location has not been changed.").font(.system(size:12*textScale)).foregroundStyle(.secondary)
                                Button("Use Codex location") {model.send(["action":"restore","id":s.id])}.font(.system(size:12*textScale))
                            }
                        }
                        Divider()

                        }
                    }.padding(22)
                }}
                VStack(spacing:10) {
                    Button {openComposer(session:s)} label: {Label("Continue in Navigator",systemImage:"square.and.pencil").frame(maxWidth:.infinity).padding(.vertical,8)}.buttonStyle(.borderedProminent)
                    Button("Read conversation") {conversationTarget=ConversationTarget(id:s.id,title:s.title)}.buttonStyle(.borderless)
                    Button {model.open(s.id)} label: {Label("Open in Codex",systemImage:"arrow.up.right.square").frame(maxWidth:.infinity).padding(.vertical,8)}.buttonStyle(.bordered)
                }.padding(20)
            } else if composerPresented {
                VStack(alignment:.leading,spacing:19) {
                    Text(inspectorComposer.title).font(.system(size:19*textScale,weight:.semibold))
                    if !inspectorComposer.cwd.isEmpty {
                        PathLink(path:inspectorComposer.cwd).font(.system(size:12*textScale))
                    }
                    Divider()
                    Text(inspectorComposer.statusLabel).foregroundStyle(.secondary)
                    Text(inspectorComposer.threadId.isEmpty ? "Session details and media will appear here after this task starts." : "Session details and media are being indexed.")
                        .font(.system(size:12*textScale)).foregroundStyle(.secondary)
                }.padding(22)
                Spacer()
            } else {
                Spacer()
                ContentUnavailableView("Select a session",systemImage:"doc.text.magnifyingglass",description:Text("Preview prompts, activity and media without opening Codex."))
                Spacer()
                newMenu.padding(20)
            }
        }.frame(maxHeight:.infinity).background(.background.opacity(0.3))
    }
    private func openComposer(target:Project?=nil,session:Session?=nil) {
        model.perform(["action":"composerOpen","id":session?.id ?? "","cwd":session?.cwd ?? target?.path ?? "","project":target?.id ?? "","title":session?.title ?? target.map{"New task in " + $0.name} ?? "New task"],undoManager:nil) {error in
            if let error {model.error=error} else {composerPresented=true}
        }
    }
    private var newMenu:some View {creationMenu(for:project)}
    private func creationMenu(for target:Project?) -> some View {
        Menu {
            Button("New task in Navigator") {openComposer(target:target)}
            Button("Open new task in Codex") {model.send(["action":"newCodex","cwd":target?.path ?? "","project":target?.id ?? ""])}.disabled(!model.connected || CommandLine.arguments.contains("--demo"))
        } label: {Label(target.map{"New in " + $0.name} ?? "New session…",systemImage:"plus")}.fixedSize()
        .help("Write and run a Codex task in Navigator, or open the Codex app.")
    }
    private func columnLabel(_ name:String)->String {name == "Date Created" ? "Created" : name == "Token Usage" ? "Token usage" : name}
    private func info(_ key:String,_ value:String) -> some View {
        HStack(alignment:.top) {Text(key).foregroundStyle(.secondary);Spacer(minLength:12);Text(value).multilineTextAlignment(.trailing)}.font(.system(size:14*textScale))
    }
    private func mediaGrid(_ s:Session,reveal:@escaping(String)->Void) -> some View {
        Group {if let error=model.detailErrors[s.id] {Text(error).foregroundStyle(.orange);Button("Retry preview") {model.send(["action":"refresh"])}} else {MediaGallery(assets:model.details[s.id]?.media ?? [],indexed:model.details[s.id] != nil && s.indexed,reveal:reveal)}}.id(s.id)
    }
    private func cell(_ s:Session,_ name:String,at date:Date) -> String {
        switch name {
        case "Modified":return dateText(s.modified)
        case "Date Created":return dateText(s.created)
        case "Active time":return s.durationLabel(at:date)
        case "Prompts":return s.indexed ? "\(s.promptCount)" : "…"
        case "Token Usage":return s.tokenUsage.map { $0.formatted() } ?? "—"
        case "Size":return s.size > 0 ? ByteCountFormatter.string(fromByteCount:Int64(s.size),countStyle:.file) : "—"
        default:return s.indexed ? "\(s.mediaCount)" : "…"
        }
    }
    private func watch() {model.watch(expanded.intersection(appearedRows).intersection(Set(filtered.map(\.id))).union(selected.map{[$0]} ?? []).union(inspectorSession.map{[$0.id]} ?? []),window:windowID)}
    private func refreshVisible() {
        visibleSessions=computeFiltered()
        selectedSessionIDs.formIntersection(Set(visibleSessions.map(\.id)))
        if let id=selected,!visibleSessions.contains(where:{$0.id==id}) {selected=visibleSessions.first(where:{selectedSessionIDs.contains($0.id)})?.id;quickLook=false}
        watch()
    }
    private func moveSelection(_ offset:Int) {
        guard !filtered.isEmpty else {return}
        let current=filtered.firstIndex{$0.id==selected} ?? (offset>0 ? -1 : filtered.count)
        selectSession(filtered[min(filtered.count-1,max(0,current+offset))].id,modifiers:NSEvent.modifierFlags.intersection(.shift))
    }
    private func beginGrouping(_ ids:Set<String>,name:String="") {
        groupingProjects=ids;groupName=name;grouping=true
    }
    private func reorderProjects(_ ids:[String],before target:String?) {
        let current=ProjectOrder.ordered(sortedProjects.map(\.id),saved:projectSort == "Custom" ? ProjectOrder.decode(customProjectOrder) : [])
        customProjectOrder=ProjectOrder.encode(ProjectOrder.move(ids,before:target,current:current))
        projectSort="Custom"
    }
    private func drop(_ providers:[NSItemProvider],to project:String="",toGroup group:String?=nil) -> Bool {
        guard let provider=providers.first,provider.canLoadObject(ofClass:NSString.self) else {return false}
        _=provider.loadObject(ofClass:NSString.self) {object,_ in
            guard let value=object as? String else {return}
            DispatchQueue.main.async {
                if value.hasPrefix("navigator-projects:") {
                    draggingProjects=false
                    guard let ids=try? JSONDecoder().decode([String].self,from:Data(value.dropFirst("navigator-projects:".count).utf8)) else {return}
                    let selection=Set(ids).intersection(Set(model.projects.map(\.id)))
                    guard !selection.isEmpty,project != "unassigned" else {return}
                    if let target=model.projects.first(where:{$0.id == project}) {
                        reorderProjects(Array(selection),before:target.id)
                    } else if project == "__custom_end__" {reorderProjects(Array(selection),before:nil)}
                    else if let group {beginGrouping(selection,name:group)}
                } else if value.hasPrefix("navigator-sessions:"),group == nil {
                    let ids=ProjectOrder.decode(String(value.dropFirst("navigator-sessions:".count)))
                    let valid=Set(model.sessions.map(\.id))
                    if !ids.isEmpty,ids.allSatisfy({valid.contains($0)}) {assignSessions(ids,to:project)}
                } else if value.hasPrefix("navigator-session:"),group == nil {
                    let id=String(value.dropFirst("navigator-session:".count))
                    if model.sessions.contains(where:{$0.id == id}) {model.assign(id,to:project)}
                }
            }
        }
        return true
    }
    private func compare(_ a:Double,_ b:Double) -> ComparisonResult {a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending}
}

struct ActivityDay: Identifiable { let id:Date; var seconds:Double }
struct ActivityChart: View {
    @AppStorage("navigator.textScale") private var textScale=1.0
    @StoredState private var cachedDays:[ActivityDay]=[]
    let sessions:[Session];let activity:[String:[Activity]]
    var now=Date()
    var selectedDay:Date?=nil
    var onSelect:((Date)->Void)?=nil
    private var data:[ActivityDay] {
        let calendar=Calendar.current,today=calendar.startOfDay(for:now)
        var days=(0..<14).reversed().map{ActivityDay(id:calendar.date(byAdding:.day,value:-$0,to:today)!,seconds:0)}
        for s in sessions {
            for item in activity[s.id] ?? [] {
                let start=Date(timeIntervalSince1970:item.start)
                let end=Date(timeIntervalSince1970:item.end > 0 ? item.end : s.running ? now.timeIntervalSince1970 : item.start)
                guard end>days[0].id,start<calendar.date(byAdding:.day,value:1,to:today)! else {continue}
                let span=end.timeIntervalSince(start)
                guard span>0 else {continue}
                let runtime=item.end>0 ? item.seconds : s.running ? span : 0
                for i in days.indices {
                    let next=calendar.date(byAdding:.day,value:1,to:days[i].id)!
                    let overlap=max(0,min(end,next).timeIntervalSince(max(start,days[i].id)))
                    days[i].seconds += runtime*overlap/span
                }
            }
        }
        return days
    }
    var body: some View {
        GeometryReader { geometry in
            let allDays=cachedDays.isEmpty ? data : cachedDays
            let count=min(14,max(3,Int(max(0,geometry.size.width-48*textScale)/(72*textScale))))
            let visible=Array(allDays.suffix(count))
            let labels=visible.enumerated().filter {(visible.count-1-$0.offset)%2 == 0}.map { $0.element.id }
            let upper=max(1,(allDays.map {$0.seconds/3600}.max() ?? 0)*1.1)
            let start=visible.first!.id
            let end=Calendar.current.date(byAdding:.day,value:1,to:allDays.last!.id)!
            Chart(visible) {day in
                BarMark(x:.value("Day",day.id,unit:.day),y:.value("Active hours",day.seconds/3600))
                    .foregroundStyle(Color.accentColor.opacity(selectedDay == nil || Calendar.current.isDate(day.id,inSameDayAs:selectedDay!) ? 1 : 0.3).gradient).cornerRadius(2)
                    .annotation(position:.overlay) {Color.clear.help(day.id.formatted(date:.abbreviated,time:.omitted)+": "+durationText(day.seconds))}
            }
            .chartOverlay {proxy in
                GeometryReader {area in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture {point in
                        guard let frame=proxy.plotFrame else {return}
                        let bounds=area[frame]
                        guard bounds.contains(point),let date:Date=proxy.value(atX:point.x-bounds.minX) else {return}
                        onSelect?(Calendar.current.startOfDay(for:date))
                    }
                }
            }
            .chartXScale(domain:start...end)
            .chartYScale(domain:0...upper)
            .chartYAxis {
                AxisMarks(position:.leading,values:[0,upper/2,upper]) {value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let n=value.as(Double.self) {Text(n.formatted(.number.precision(.fractionLength(0...1)))+"h").font(.system(size:12*textScale)).frame(width:48*textScale,alignment:.trailing)}
                    }
                }
            }
            .chartXAxis {AxisMarks(values:labels) {_ in AxisValueLabel(format:.dateTime.day().month(.abbreviated)).font(.system(size:12*textScale))}}
            .onAppear {cachedDays=data}
            .onChange(of:now) {_,_ in cachedDays=data}
            .onChange(of:activity) {_,_ in cachedDays=data}
            .onChange(of:sessions) {_,_ in cachedDays=data}
            .transaction {$0.animation=nil}
            .accessibilityLabel("Active runtime by day, last \(count) days. Widen the panel to show older days.")
        }
    }
}
