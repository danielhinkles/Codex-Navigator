import AppKit

struct Project {let id,name,path:String}

@main struct ProjectLauncherCheck {
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("Navigator launch check " + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let script=root.appendingPathComponent("main ' $ game.py")
        try "import os, pathlib\npathlib.Path('result.txt').write_text(os.getcwd())\n".write(to:script,atomically:true,encoding:.utf8)
        let quoted=LaunchPlan.shellQuote("a path with 'quotes'")
        precondition(quoted.first == "'" && quoted.last == "'" && quoted.contains("'\\''"))
        let custom=LaunchPlan(title:"Custom",kind:"command",path:root.path,command:"npm run dev -- --host localhost")
        precondition(custom.commandForDisplay == custom.command)
        precondition(LaunchPlan(title:"Python",kind:"python",path:script.path).commandForDisplay == "python3 \(LaunchPlan.shellQuote(script.path))" )
        let process=ProjectLauncher.scriptProcess(script)!
        precondition(process.executableURL?.path == "/usr/bin/python3")
        precondition(process.arguments == [script.path])
        try process.run();process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let workingFolder=try String(contentsOf:root.appendingPathComponent("result.txt"),encoding:.utf8)
        precondition(URL(fileURLWithPath:workingFolder).resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        precondition(ProjectLauncher.scriptProcess(root.appendingPathComponent("Game.app")) == nil)
        precondition(ProjectLauncher.scriptProcess(root.appendingPathComponent("index.html")) == nil)
        let failure=root.appendingPathComponent("failure.py")
        try "raise RuntimeError('launch check')\n".write(to:failure,atomically:true,encoding:.utf8)
        var failureMessage=""
        ProjectLauncher.open(failure) {failureMessage=$0}
        let deadline=Date().addingTimeInterval(10)
        while failureMessage.isEmpty && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
        precondition(failureMessage.contains("Launch exited with status"))
        if let log=failureMessage.components(separatedBy:"Launch details: ").last {try? FileManager.default.removeItem(atPath:log)}
        let web=root.appendingPathComponent("Web")
        try FileManager.default.createDirectory(at:web,withIntermediateDirectories:true)
        try "{\"scripts\":{\"dev\":\"vite\",\"deploy\":\"never run\"},\"packageManager\":\"pnpm@10.0.0\"}".write(to:web.appendingPathComponent("package.json"),atomically:true,encoding:.utf8)
        let game=root.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at:game.appendingPathComponent("ProjectSettings"),withIntermediateDirectories:true)
        try "m_EditorVersion: 6000.6.0f1".write(to:game.appendingPathComponent("ProjectSettings/ProjectVersion.txt"),atomically:true,encoding:.utf8)
        let app=game.appendingPathComponent("Builds/Mac/Game.app")
        try FileManager.default.createDirectory(at:app,withIntermediateDirectories:true)
        let godot=root.appendingPathComponent("Godot")
        try FileManager.default.createDirectory(at:godot,withIntermediateDirectories:true)
        try "".write(to:godot.appendingPathComponent("project.godot"),atomically:true,encoding:.utf8)
        let ignored=root.appendingPathComponent("node_modules/ignored")
        try FileManager.default.createDirectory(at:ignored,withIntermediateDirectories:true)
        try "".write(to:ignored.appendingPathComponent("main.py"),atomically:true,encoding:.utf8)
        let plans=LaunchDiscovery.plans(root:root)
        precondition(plans.contains{$0.kind=="open" && URL(fileURLWithPath:$0.path).resolvingSymlinksInPath()==app.resolvingSymlinksInPath()})
        precondition(plans.contains{$0.kind=="unity" && URL(fileURLWithPath:$0.path).resolvingSymlinksInPath()==game.resolvingSymlinksInPath()})
        precondition(plans.contains{$0.kind=="godot" && URL(fileURLWithPath:$0.path).resolvingSymlinksInPath()==godot.resolvingSymlinksInPath()})
        precondition(plans.contains{$0.command=="pnpm run dev"})
        precondition(!plans.contains{$0.command.contains("deploy") || $0.path.contains("node_modules")})
        precondition(LaunchDiscovery.file(web.appendingPathComponent("package.json")) == nil)
        // Detection must not write launch files or change project contents.
        let before=try FileManager.default.subpathsOfDirectory(atPath:root.path).sorted()
        _=LaunchDiscovery.plans(root:root)
        let after=try FileManager.default.subpathsOfDirectory(atPath:root.path).sorted()
        precondition(before==after)
        if CommandLine.arguments.contains("--ui") {
            let application=NSApplication.shared
            application.setActivationPolicy(.regular);application.activate(ignoringOtherApps:true)
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                guard let view=application.modalWindow?.contentView else {preconditionFailure("Missing launch setup window")}
                if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:"/tmp/navigator-launch-setup.png"))
                }
                application.abortModal()
            }
            ProjectLauncher.select(plans,project:Project(id:"launcher-check",name:"Launch check",path:root.path)) {preconditionFailure($0)}
        }
        // Opt-in probe against real project folders: NAVIGATOR_CHECK_PROJECTS="/path/one:/path/two".
        if CommandLine.arguments.contains("--actual-projects") {
            let roots=(ProcessInfo.processInfo.environment["NAVIGATOR_CHECK_PROJECTS"] ?? "").split(separator:":").map(String.init)
            for root in roots {
                let path=URL(fileURLWithPath:root)
                let found=LaunchDiscovery.plans(root:path)
                print(path.lastPathComponent + ": " + found.map(\.title).joined(separator:" | "))
                precondition(!found.isEmpty)
            }
        }
        print("Project launcher check passed: Python execution, literal paths, working folder, app/web routing, failure reporting")
    }
}
