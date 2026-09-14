import Foundation
@main struct ProjectOrderCheck {
    static func main() {
        if CommandLine.arguments.count == 4,CommandLine.arguments[1] == "--verify-saved" {
            let prefs=UserDefaults(suiteName:CommandLine.arguments[2])!
            precondition(prefs.string(forKey:"navigator.customProjectOrder") == CommandLine.arguments[3])
            return
        }
        let ids=["a","b","c","d"]
        precondition(ProjectOrder.move(["c"],before:"a",current:ids)==["c","a","b","d"])
        precondition(ProjectOrder.move(["a","c"],before:nil,current:ids)==["b","d","a","c"])
        precondition(ProjectOrder.move(["a","b"],before:"b",current:ids)==ids)
        precondition(ProjectOrder.ordered(["a","c","new"],saved:["c","removed","a","a"])==["c","a","new"])
        let suite="navigator-order-check-"+UUID().uuidString
        let prefs=UserDefaults(suiteName:suite)!
        let order=ProjectOrder.move(["d"],before:"b",current:ids)
        prefs.set(ProjectOrder.encode(order),forKey:"navigator.customProjectOrder")
        prefs.set("Alphabetical",forKey:"navigator.projectSort")
        precondition(ProjectOrder.decode(prefs.string(forKey:"navigator.customProjectOrder")!)==["a","d","b","c"])
        prefs.set("Custom",forKey:"navigator.projectSort")
        precondition(ProjectOrder.ordered(ids,saved:ProjectOrder.decode(prefs.string(forKey:"navigator.customProjectOrder")!))==order)
        precondition(prefs.synchronize())
        let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--verify-saved",suite,ProjectOrder.encode(order)]
        try! child.run();child.waitUntilExit();precondition(child.terminationStatus == 0)
        prefs.removePersistentDomain(forName:suite)
        print("Project order checks passed: reordering, multi-selection, missing/new IDs, cross-process persistence and Custom restore; only isolated Navigator preferences written.")
    }
}
