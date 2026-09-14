import Foundation
@main struct SessionSelectionCheck {
    static func main() {
        precondition(SessionSelection.inspectorID(selected:"sprite-session",composerPresented:true,threadID:"") == nil)
        precondition(SessionSelection.inspectorID(selected:"sprite-session",composerPresented:true,threadID:"navigator-session") == "navigator-session")
        precondition(SessionSelection.inspectorID(selected:"sprite-session",composerPresented:false,threadID:"navigator-session") == "sprite-session")
        let ids=["a","b","c","d"]
        precondition(SessionSelection.select("c",visible:ids,selected:["a"],anchor:"a",extending:true,toggling:false)==["a","b","c"])
        precondition(SessionSelection.select("a",visible:ids,selected:["a","c"],anchor:nil,extending:false,toggling:true)==["c"])
        precondition(SessionSelection.select("d",visible:ids,selected:["a"],anchor:"c",extending:true,toggling:true)==["a","c","d"])
        precondition(SessionSelection.select("b",visible:ids,selected:["a","c"],anchor:nil,extending:false,toggling:false)==["b"])
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let day=Date(timeIntervalSince1970:86400)
        precondition(SessionSelection.hasActivity(day:day,intervals:[(86000,87000,1000)],running:false,calendar:calendar))
        precondition(!SessionSelection.hasActivity(day:day,intervals:[(80000,86400,6400)],running:false,calendar:calendar))
        precondition(!SessionSelection.hasActivity(day:day,intervals:[(86500,0,0)],running:false,calendar:calendar))
        precondition(SessionSelection.hasActivity(day:day,intervals:[(86500,0,0)],running:true,now:Date(timeIntervalSince1970:87000),calendar:calendar))
        print("Session selection and recorded activity date checks passed.")
    }
}
