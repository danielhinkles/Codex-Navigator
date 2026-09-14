import Foundation

/// Order is Navigator metadata; it never touches projects or directories.
enum ProjectOrder {
    static func decode(_ value:String)->[String] {(try? JSONDecoder().decode([String].self,from:Data(value.utf8))) ?? []}
    static func encode(_ ids:[String])->String {String(decoding:(try? JSONEncoder().encode(ids)) ?? Data(),as:UTF8.self)}
    static func ordered(_ current:[String],saved:[String])->[String] {
        let valid=Set(current);var seen=Set<String>()
        return (saved+current).filter{valid.contains($0) && seen.insert($0).inserted}
    }
    static func move(_ moving:[String],before target:String?,current:[String])->[String] {
        let selected=Set(moving);let moved=current.filter{selected.contains($0)}
        guard !moved.isEmpty,target.map({!selected.contains($0)}) ?? true else {return current}
        var result=current.filter{!selected.contains($0)}
        result.insert(contentsOf:moved,at:target.flatMap{result.firstIndex(of:$0)} ?? result.count)
        return result
    }
}
