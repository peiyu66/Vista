import Foundation

public enum BubbleFlow {
    public static func positions(sizes:[CGSize],width:CGFloat,spacing:CGFloat=8)->(points:[CGPoint],height:CGFloat) {
        let limit=max(1,width)
        var x:CGFloat=0,y:CGFloat=0,row:CGFloat=0
        var result:[CGPoint]=[]
        for size in sizes {
            let w=min(limit,max(0,size.width)),h=max(0,size.height)
            if x>0,x+w>limit {x=0;y += row+spacing;row=0}
            result.append(CGPoint(x:x,y:y));x += w+spacing;row=max(row,h)
        }
        return (result,sizes.isEmpty ? 0:y+row)
    }
}
