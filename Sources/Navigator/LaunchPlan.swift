import Foundation

struct LaunchPlan:Codable,Equatable {
    var title:String
    var kind:String
    var path:String
    var command:String = ""
    var browserURL:String = ""

    /// The command represented by a saved plan, suitable for display or copying.
    /// Custom commands are returned byte-for-byte so setup never rewrites user input.
    var commandForDisplay:String? {
        switch kind {
        case "command": return command.isEmpty ? nil : command
        case "python": return "python3 \(Self.shellQuote(path))"
        case "shell": return "/bin/bash \(Self.shellQuote(path))"
        case "executable": return Self.shellQuote(path)
        case "godot": return "godot --path \(Self.shellQuote(path))"
        case "unity": return "unity -projectPath \(Self.shellQuote(path))"
        case "open": return "open \(Self.shellQuote(path))"
        default: return nil
        }
    }

    /// POSIX shell quoting for paths shown in a copyable command.
    static func shellQuote(_ value:String)->String {
        "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'"
    }
}

enum LaunchDiscovery {
    static let excluded:Set<String>=["node_modules","Library","Temp","Logs","obj",".git",".next",".vinext","Assets","Packages"]
    static func plans(root:URL)->[LaunchPlan] {
        var apps:[URL]=[], projects:[LaunchPlan]=[], web:[LaunchPlan]=[]
        var visited=0
        func scan(_ directory:URL,_ depth:Int) {
            guard depth<=3,visited<500 else {return};visited+=1
            let fm=FileManager.default
            let package=directory.appendingPathComponent("package.json")
            var hasWeb=false
            if let data=try? Data(contentsOf:package),let obj=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let scripts=obj["scripts"] as? [String:String] {
                let declared=(obj["packageManager"] as? String)?.components(separatedBy:"@").first
                let manager=declared.flatMap{["npm","pnpm","yarn","bun"].contains($0) ? $0 : nil} ?? (["pnpm-lock.yaml":"pnpm","yarn.lock":"yarn","bun.lock":"bun","bun.lockb":"bun"].sorted{$0.key<$1.key}.first{fm.fileExists(atPath:directory.appendingPathComponent($0.key).path)}?.value ?? "npm")
                for script in ["dev","start","serve"] where scripts[script] != nil {
                    hasWeb=true
                    web.append(LaunchPlan(title:"Web · \(manager) run \(script) · \(relative(directory,root))",kind:"command",path:directory.path,command:"\(manager) run \(script)"))
                }
            }
            let unity=directory.appendingPathComponent("ProjectSettings/ProjectVersion.txt")
            if fm.fileExists(atPath:unity.path) {projects.append(LaunchPlan(title:"Unity editor · \(relative(directory,root)) (press Play in Unity)",kind:"unity",path:directory.path))}
            if fm.fileExists(atPath:directory.appendingPathComponent("project.godot").path) {projects.append(LaunchPlan(title:"Run Godot game · \(relative(directory,root))",kind:"godot",path:directory.path))}
            if !hasWeb,fm.fileExists(atPath:directory.appendingPathComponent("index.html").path) {web.append(LaunchPlan(title:"Local website · \(relative(directory,root))",kind:"static",path:directory.appendingPathComponent("index.html").path))}
            if fm.fileExists(atPath:directory.appendingPathComponent("main.py").path) {projects.append(LaunchPlan(title:"Python · \(relative(directory,root))/main.py",kind:"python",path:directory.appendingPathComponent("main.py").path))}
            guard let entries=try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:.skipsHiddenFiles) else {return}
            for entry in entries.sorted(by:{$0.path<$1.path}) {
                guard !excluded.contains(entry.lastPathComponent),let values=try? entry.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),values.isSymbolicLink != true else {continue}
                if entry.pathExtension.lowercased()=="app" {apps.append(entry)}
                else if values.isDirectory == true {scan(entry,depth+1)}
            }
        }
        scan(root,0)
        apps.sort {
            let a=(try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b=(try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a==b ? $0.path<$1.path : a>b
        }
        return apps.map{LaunchPlan(title:"App · " + relative($0,root),kind:"open",path:$0.path)} + web + projects
    }
    static func relative(_ url:URL,_ root:URL)->String {url==root ? root.lastPathComponent : String(url.path.dropFirst(root.path.count+1))}
    static func file(_ url:URL)->LaunchPlan? {
        switch url.pathExtension.lowercased() {
        case "app":return LaunchPlan(title:url.lastPathComponent,kind:"open",path:url.path)
        case "py":return LaunchPlan(title:url.lastPathComponent,kind:"python",path:url.path)
        case "html","htm":return LaunchPlan(title:url.lastPathComponent,kind:"static",path:url.path)
        case "godot":return LaunchPlan(title:"Run Godot game",kind:"godot",path:url.deletingLastPathComponent().path)
        case "sh","command":return LaunchPlan(title:url.lastPathComponent,kind:"shell",path:url.path)
        default:
            if FileManager.default.isExecutableFile(atPath:url.path) {return LaunchPlan(title:url.lastPathComponent,kind:"executable",path:url.path)}
            return nil
        }
    }
}
