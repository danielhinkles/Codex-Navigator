import Foundation

/// Selection is view metadata only. Neither this type nor its callers move source files.
enum SessionSelection {
    static func inspectorID(selected:String?,composerPresented:Bool,threadID:String)->String? {
        composerPresented ? (threadID.isEmpty ? nil : threadID) : selected
    }

    static func select(_ id:String, visible:[String], selected:Set<String>, anchor:String?, extending:Bool, toggling:Bool)->Set<String> {
        guard visible.contains(id) else {return selected.intersection(visible)}
        if extending,let anchor,let a=visible.firstIndex(of:anchor),let b=visible.firstIndex(of:id) {
            let range=Set(visible[min(a,b)...max(a,b)])
            return toggling ? selected.union(range) : range
        }
        if toggling {var value=selected; if !value.insert(id).inserted {value.remove(id)};return value}
        return [id]
    }
    static func hasActivity(day:Date, intervals:[(start:Double,end:Double,seconds:Double)], running:Bool, now:Date=Date(),calendar:Calendar = .current)->Bool {
        let start=calendar.startOfDay(for:day).timeIntervalSince1970
        guard let next=calendar.date(byAdding:.day,value:1,to:calendar.startOfDay(for:day)) else {return false}
        return intervals.contains {item in
            let end=item.end > 0 ? item.end : running ? now.timeIntervalSince1970 : item.start
            return (item.seconds > 0 || running && item.end == 0) && end>start && item.start<next.timeIntervalSince1970 && end>item.start
        }
    }
}
