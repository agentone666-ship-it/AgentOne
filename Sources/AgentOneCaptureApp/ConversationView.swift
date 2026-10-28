import SwiftUI

private func discussionTime(_ value:String?) -> String {
    guard let ms=Double(value ?? "") else {return ""}
    return Date(timeIntervalSince1970:ms/1000).formatted(date:.abbreviated,time:.shortened)
}
private func discussionDuration(_ row:[String:String]) -> String {
    let seconds=max(0,(Double(row["ended_ms"] ?? "") ?? 0)-(Double(row["started_ms"] ?? "") ?? 0))/1000
    return seconds<60 ? "不足1分钟":"约\(Int(ceil(seconds/60)))分钟"
}
private func discussionStatus(_ row:[String:String]) -> String {
    switch row["state"] {case "open":return "讨论进行中 · 保留短暂停顿";case "processing":return "整场转写处理中";default:return "讨论已结束"}
}
struct ConversationCard: View {
    let row:[String:String]
    let busy:Bool
    let onPlay:()->Void,onRead:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("声音会话").font(.system(size:13,weight:.semibold))
            Text(discussionTime(row["started_ms"])+" — "+discussionTime(row["ended_ms"])).font(.system(size:10)).foregroundStyle(.white.opacity(0.5))
            Text(discussionStatus(row)).font(.system(size:10)).foregroundStyle(.mint)
            Text("转写片语："+(row["preview_text"] ?? "等待完整转写")).font(.system(size:11)).lineLimit(3).foregroundStyle(.white.opacity(0.75))
            if let missing=Int(row["missing_ms"] ?? ""),missing>250 {Text("原音约有 \(max(1,missing/1000)) 秒缺口；回放以静音呈现").font(.system(size:10)).foregroundStyle(.orange)}
            HStack {
                Button(busy ? "正在准备回放…":row["state"]=="open" ? "回放已保存部分":"整场回放",action:onPlay).disabled(busy)
                Button("整场原文",action:onRead)
                Spacer()
                Text(discussionDuration(row)).foregroundStyle(.white.opacity(0.4))
            }.font(.system(size:10)).buttonStyle(.plain)
        }.padding(12).background(.white.opacity(0.055),in:RoundedRectangle(cornerRadius:12))
    }
}
struct ConversationDetail:View {
    let row:[String:String]?
    let onPlay:()->Void,onTranscribe:()->Void,onClose:()->Void
    let busy:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text("整场声音会话").font(.title3.bold());Spacer();Button("关闭",action:onClose)}
            if let row {
                Text(discussionTime(row["started_ms"])+" — "+discussionTime(row["ended_ms"])).font(.caption)
                Text(discussionStatus(row)).foregroundStyle(.secondary)
                Text("以下是归并后的整场转写，可能有识别误差。原音保留；人物与话题边界未经确认。").font(.caption).foregroundStyle(.secondary)
                if let missing=Int(row["missing_ms"] ?? ""),missing>250 {Text("原音约有 \(max(1,missing/1000)) 秒缺口，回放相应位置以静音呈现。").font(.caption).foregroundStyle(.orange)}
                ScrollView {Text(row["transcript_text"] ?? "").font(.system(size:12)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}
                HStack {Button(busy ? "正在生成…":"整场回放",action:onPlay).disabled(busy);Button("补全旧版转写",action:onTranscribe)}
                Text("按人声和时间自动归并，未识别发言者；尚未转写的人声可能使场次边界变化。").font(.caption2).foregroundStyle(.secondary)
            } else {Text("来源已删除或讨论已重新归并，请返回列表重新打开。").foregroundStyle(.secondary)}
        }.padding(24).frame(width:640,height:560)
    }
}
