import SwiftUI

/// Every bar is a recent measured mixed-PCM level, ordered oldest to newest.
struct LiveAudioGlyph: View {
    let levels:[Double]
    let recording:Bool
    var size:CGFloat=20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        HStack(spacing:size*0.09) {
            ForEach(0..<5,id:\.self) {index in
                Capsule().frame(width:size*0.115,height:height(index))
            }
        }.frame(width:size,height:size)
            .animation(reduceMotion ? nil:.easeOut(duration:0.09),value:levels)
            .accessibilityHidden(true)
    }
    private func height(_ index:Int) -> CGFloat {
        if !recording {return size*[0.22,0.48,0.75,0.48,0.22][index]}
        let level=levels.indices.contains(index) ? levels[index]:0
        return size*(0.14+0.86*min(1,max(0,level)))
    }
}
