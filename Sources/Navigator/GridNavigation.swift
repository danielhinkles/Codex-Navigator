import Foundation

/// Arrow keys follow the rendered thumbnail rows. No wrapping across an edge.
enum GridNavigation {
    static func columns(width:Double,minimum:Double,spacing:Double=8)->Int {
        max(1,Int((max(0,width)+spacing)/(minimum+spacing)))
    }
    static func next(index:Int,count:Int,columns:Int,key:UInt16)->Int {
        guard count>0 else {return 0}
        let i=min(count-1,max(0,index)),c=max(1,columns)
        switch key {
        case 123:return i%c>0 ? i-1 : i
        case 124:return i%c<c-1 && i+1<count ? i+1 : i
        case 126:return i>=c ? i-c : i
        case 125:return (i/c+1)*c<count ? min(count-1,i+c) : i
        default:return i
        }
    }
}
