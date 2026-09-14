import AppKit

extension Bundle {
    /// Running from `swift build` (no .app wrapper) uses the checkout's backend folder.
    /// A packaged app never executes scripts from whatever directory it was opened in.
    static func developmentScript(_ name: String) -> URL {
        let packaged = Bundle.main.bundleURL.pathExtension == "app"
        let base = packaged ? (Bundle.main.resourceURL ?? Bundle.main.bundleURL) : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.appendingPathComponent("backend/" + name)
    }
}

/// The observable state of one explicit launch target.
/// `opened` is used for targets handed to another application (native `.app`
/// bundles and the Unity editor), which Navigator does not own.
enum LaunchStatus:Equatable,CustomStringConvertible {
    case idle
    case running
    case opened
    case exited(Int32)

    var description:String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .opened: return "Opened externally"
        case .exited(let code): return code == 0 ? "Exited" : "Exited (status \(code))"
        }
    }
    var isActive:Bool {self == .running || self == .opened}
}

/// All launch preferences belong to Navigator. Only an explicit launch runs project code.
enum ProjectLauncher {
    static let launchChangedNotification=Notification.Name("NavigatorLaunchChanged")
    // Process termination callbacks may arrive off the main queue. Keep the
    // status contract safe for menu and test callers as well.
    private static let stateLock=NSLock()
    private static var owned:[String:Process]=[:]
    private static var logs:[String:URL]=[:]
    private static var states:[String:LaunchStatus]=[:]
    private static var externalApps:[String:NSRunningApplication]=[:]
    private static var externalObservers:[String: NSObjectProtocol]=[:]

    /// Injectable for demo and isolated native checks. Production uses standard defaults.
    private static var preferences:UserDefaults = .standard
    static func usePreferences(_ defaults:UserDefaults) {preferences=defaults}

    static func key(_ project:Project)->String {"navigator.launchTarget." + project.id}
    static func planKey(_ project:Project)->String {"navigator.launchPlan." + project.id}

    /// Current lifecycle state, without exposing owned Process instances.
    static func status(for project:Project)->LaunchStatus {status(for:project.id)}
    static func status(for id:String)->LaunchStatus {
        stateLock.lock(); defer {stateLock.unlock()}
        return states[id] ?? .idle
    }
    static func launchStatus(for project:Project)->LaunchStatus {status(for:project)}
    static func launchStatus(for id:String)->LaunchStatus {status(for:id)}

    static func candidates(root:URL)->[URL] {LaunchDiscovery.plans(root:root).filter{$0.kind=="open" || $0.kind=="static"}.map{URL(fileURLWithPath:$0.path)} }
    static func saved(_ project:Project)->LaunchPlan? {
        if let data=preferences.data(forKey:planKey(project)),let plan=try? JSONDecoder().decode(LaunchPlan.self,from:data) {return plan}
        if let path=preferences.string(forKey:key(project)) {return LaunchDiscovery.file(URL(fileURLWithPath:path))}
        return nil
    }
    static func save(_ plan:LaunchPlan,project:Project) {
        if let data=try? JSONEncoder().encode(plan) {
            preferences.set(data,forKey:planKey(project));preferences.removeObject(forKey:key(project))
            notify(project.id)
        }
    }

    /// Presentation hooks for project menus. Missing means there is no saved setup.
    static func launchLabel(for project:Project)->String? {saved(project)?.title}
    static func savedLaunchLabel(for project:Project)->String? {launchLabel(for:project)}
    static func launchCommand(for project:Project)->String? {saved(project)?.commandForDisplay}
    static func copyLaunchCommand(for project:Project)->Bool {
        guard let command=launchCommand(for:project) else {return false}
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(command,forType:.string)
    }

    static func launchLatest(project:Project,report:@escaping(String)->Void) {
        if let plan=saved(project) {launch(plan,id:project.id,report:report);return}
        discover(project:project) {plans in
            if plans.count==1 {save(plans[0],project:project);launch(plans[0],id:project.id,report:report)}
            else {select(plans,project:project,report:report)}
        }
    }
    static func discover(project:Project,completion:@escaping([LaunchPlan])->Void) {
        DispatchQueue.global(qos:.userInitiated).async {
            let plans=LaunchDiscovery.plans(root:URL(fileURLWithPath:project.path))
            DispatchQueue.main.async {completion(plans)}
        }
    }
    static func configure(project:Project,report:@escaping(String)->Void) {discover(project:project) {select($0,project:project,report:report)}}
    static func select(_ plans:[LaunchPlan],project:Project,report:@escaping(String)->Void) {
        let alert=NSAlert()
        alert.messageText="Launch " + project.name
        alert.informativeText="Choose how to run this project. Navigator remembers your choice. Web servers open in your browser when ready; use Stop launched process to stop them. Web servers also stop when Navigator quits."
        let picker=NSPopUpButton(frame:NSRect(x:0,y:0,width:580,height:28))
        picker.addItems(withTitles:plans.map(\.title)+["Choose a file…","Custom command…"])
        if let saved=saved(project),let index=plans.firstIndex(of:saved) {picker.selectItem(at:index)}
        alert.accessoryView=picker
        alert.addButton(withTitle:"Save & Launch");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {return}
        let index=picker.indexOfSelectedItem
        if index<plans.count {save(plans[index],project:project);launch(plans[index],id:project.id,report:report)}
        else if index==plans.count {choose(project:project,report:report)}
        else {custom(project:project,report:report)}
    }
    static func custom(project:Project,report:@escaping(String)->Void) {
        let alert=NSAlert();alert.messageText="Custom launch for " + project.name
        alert.informativeText="Enter the command you normally use in Terminal. Output appears in the launch log. An optional localhost address opens when ready."
        let previous=saved(project)
        let command=NSTextField(string:previous?.kind=="command" ? previous?.command ?? "" : "")
        command.placeholderString="For example: npm run dev"
        let folder=NSTextField(string:previous?.kind=="command" ? previous?.path ?? project.path : project.path)
        let browser=NSTextField(string:previous?.browserURL ?? "");browser.placeholderString="Optional: http://localhost:3000"
        let stack=NSStackView(views:[NSTextField(labelWithString:"Command"),command,NSTextField(labelWithString:"Working folder"),folder,NSTextField(labelWithString:"Browser address"),browser])
        stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=6
        stack.frame=NSRect(x:0,y:0,width:580,height:160)
        for field in [command,folder,browser] {field.widthAnchor.constraint(equalToConstant:580).isActive=true}
        alert.accessoryView=stack;alert.addButton(withTitle:"Save & Launch");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {return}
        guard !command.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {report("Enter a launch command.");return}
        guard folder.stringValue.hasPrefix("/"),FileManager.default.fileExists(atPath:folder.stringValue) else {report("Choose an available absolute working folder.");return}
        if !browser.stringValue.isEmpty {
            guard let url=URL(string:browser.stringValue),["http","https"].contains(url.scheme ?? ""),["localhost","127.0.0.1","[::1]","::1"].contains(url.host ?? "") else {report("Use a localhost HTTP or HTTPS browser address.");return}
        }
        let plan=LaunchPlan(title:"Custom · " + project.name,kind:"command",path:folder.stringValue,command:command.stringValue,browserURL:browser.stringValue)
        save(plan,project:project);launch(plan,id:project.id,report:report)
    }
    static func choose(project:Project,report:@escaping(String)->Void) {
        let panel=NSOpenPanel();panel.title="Choose launch target for " + project.name
        panel.message="Select an app, HTML page, Python or shell script, executable, or project.godot."
        panel.prompt="Save & Launch";panel.canChooseDirectories=false;panel.canChooseFiles=true;panel.allowsMultipleSelection=false
        panel.directoryURL=project.path.isEmpty ? nil : URL(fileURLWithPath:project.path)
        panel.begin {result in
            guard result == .OK,let url=panel.url else {return}
            guard let plan=LaunchDiscovery.file(url) else {report("This file is not a supported launch target. Use Launch setup… to choose a custom command.");return}
            save(plan,project:project);launch(plan,id:project.id,report:report)
        }
    }
    /// Stops only the helper process owned by Navigator. External `.app` and
    /// Unity processes have `.opened` state and are deliberately left alone.
    static func stop(project:Project) {
        stateLock.lock();let process=owned[project.id];stateLock.unlock()
        if process?.isRunning == true {process?.terminate()}
    }
    static func showLog(project:Project,report:@escaping(String)->Void) {
        stateLock.lock();let log=logs[project.id];stateLock.unlock()
        guard let log else {report("No launch log yet. Launch the project first.");return}
        NSWorkspace.shared.open(log)
    }

    static func scriptProcess(_ url:URL)->Process? {
        guard url.pathExtension.lowercased()=="py" else {return nil}
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3");process.arguments=[url.path];process.currentDirectoryURL=url.deletingLastPathComponent();return process
    }
    static func open(_ url:URL,report:@escaping(String)->Void) {
        guard let plan=LaunchDiscovery.file(url) else {report("Choose a supported target or a custom launch command.");return}
        launch(plan,id:url.path,report:report)
    }

    private static func begin(_ id:String,state:LaunchStatus,allowOpened:Bool=false)->Bool {
        stateLock.lock()
        guard states[id] != .running && !(states[id] == .opened && !allowOpened) else {stateLock.unlock();return false}
        states[id]=state
        stateLock.unlock()
        notify(id)
        return true
    }
    private static func setState(_ state:LaunchStatus,id:String) {
        stateLock.lock();states[id]=state;stateLock.unlock()
        notify(id)
    }
    private static func notify(_ id:String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name:launchChangedNotification,object:id)
        }
    }
    static func launch(_ plan:LaunchPlan,id:String,report:@escaping(String)->Void) {
        // Unity hands off through the helper and cannot provide a stable
        // NSRunningApplication, so a later handoff is allowed.
        guard begin(id,state:plan.kind=="open" ? .opened : .running,allowOpened:plan.kind=="unity") else {report("This project already has a launched process. Stop it before launching again.");return}
        guard FileManager.default.fileExists(atPath:plan.path) else {setState(.exited(1),id:id);report("The launch target is unavailable. Choose Launch setup… to update it.");return}
        if plan.kind=="open" {
            NSWorkspace.shared.open(URL(fileURLWithPath:plan.path),configuration:NSWorkspace.OpenConfiguration()) {application,error in
                if let error {setState(.exited(1),id:id);DispatchQueue.main.async {report(error.localizedDescription)}}
                else if let application {
                    let token=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didTerminateApplicationNotification,object:nil,queue:.main) {note in
                        guard let ended=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {return}
                        stateLock.lock()
                        let matches=externalApps[id]?.processIdentifier == ended.processIdentifier
                        if matches {
                            externalApps.removeValue(forKey:id)
                            if let observer=externalObservers.removeValue(forKey:id) {
                                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                            }
                        }
                        stateLock.unlock()
                        if matches {setState(.exited(0),id:id)}
                    }
                    stateLock.lock();externalApps[id]=application;externalObservers[id]=token;stateLock.unlock()
                }
            }
            return
        }
        let bundled=Bundle.main.resourceURL?.appendingPathComponent("backend/launcher.py")
        let helper=bundled.flatMap{FileManager.default.fileExists(atPath:$0.path) ? $0 : nil} ?? Bundle.developmentScript("launcher.py")
        let process=Process(),log=FileManager.default.temporaryDirectory.appendingPathComponent("navigator-launch-" + UUID().uuidString + ".log")
        do {
            guard FileManager.default.createFile(atPath:log.path,contents:nil) else {setState(.exited(1),id:id);report("Could not create a launch log.");return}
            let output=try FileHandle(forWritingTo:log)
            process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            // The plan (including any custom command text) goes over stdin so it never appears in `ps` output.
            let planData=try JSONEncoder().encode(plan)
            process.arguments=[helper.path,"--stdin"]
            let input=Pipe()
            var env=ProcessInfo.processInfo.environment
            env["PATH"]=(env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["PYTHONUNBUFFERED"]="1";process.environment=env
            process.standardOutput=output;process.standardError=output;process.standardInput=input
            process.terminationHandler={ended in
                try? output.close()
                stateLock.lock()
                if owned[id] === ended {owned.removeValue(forKey:id)}
                stateLock.unlock()
                let successful=ended.terminationStatus == 0
                setState(plan.kind=="unity" && successful ? .opened : .exited(ended.terminationStatus),id:id)
                DispatchQueue.main.async {
                    if !successful {report("Launch exited with status \(ended.terminationStatus). Use Show launch log for details. Launch details: \(log.path)")}
                }
            }
            do {
                try process.run();stateLock.lock();owned[id]=process;logs[id]=log;stateLock.unlock()
                try? input.fileHandleForWriting.write(contentsOf:planData);try? input.fileHandleForWriting.close()
            }
            catch {try? output.close();try? FileManager.default.removeItem(at:log);setState(.exited(1),id:id);report("Could not launch: " + error.localizedDescription)}
        } catch {setState(.exited(1),id:id);report("Could not prepare the launch: " + error.localizedDescription)}
    }
}
