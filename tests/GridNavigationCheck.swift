import Foundation
@main struct GridNavigationCheck {
    static func main() {
        precondition(GridNavigation.columns(width:228,minimum:110)==2)
        precondition(GridNavigation.columns(width:345,minimum:110)==2)
        precondition(GridNavigation.columns(width:346,minimum:110)==3)
        for columns in 1...6 {
            for count in 1...20 {
                for i in 0..<count {
                    let l=GridNavigation.next(index:i,count:count,columns:columns,key:123)
                    let r=GridNavigation.next(index:i,count:count,columns:columns,key:124)
                    let u=GridNavigation.next(index:i,count:count,columns:columns,key:126)
                    let d=GridNavigation.next(index:i,count:count,columns:columns,key:125)
                    precondition(l/columns==i/columns && r/columns==i/columns)
                    precondition(u==i || u==i-columns)
                    precondition(d==i || (d/columns==i/columns+1 && d==min(count-1,i+columns)))
                    precondition([l,r,u,d].allSatisfy{(0..<count).contains($0)})
                }
            }
        }
        print("Grid navigation passed: four directions, row boundaries, incomplete rows, single columns and responsive widths.")
    }
}
