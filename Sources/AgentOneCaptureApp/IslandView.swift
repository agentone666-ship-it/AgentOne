import AgentOneCaptureKit
import AppKit
import SwiftUI

/// A quiet surface: recording at a glance, evidence on demand, controls one tab away.
struct IslandView: View {
    @ObservedObject var model: CaptureModel
    var onExpand: (() -> Void)? = nil
    @State private var tab = IslandTab.capture
    @State private var showEvents = false
    @State private var expandedEventID: String?
    private let accent = Color(red: 0.55,green: 0.9,blue: 0.84)
    private var status: String { model.demo ? "界面演示" : model.hasError ? "需要留意" : model.recording ? (model.automaticRecording ? "自动记录中" : "记录中") : model.listening ? "听候中" : "未录音" }
    private var tint: Color { model.hasError ? .orange : model.recording ? accent : model.listening ? .cyan : .white.opacity(0.45) }
    private var notched: Bool { model.notchHeight > 0 }
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: notched ? 0 : 20,bottomLeadingRadius: model.expanded ? 30 : 12,bottomTrailingRadius: model.expanded ? 30 : 12,topTrailingRadius: notched ? 0 : 20)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.expanded {
                if notched { hardwareHeader }
                expandedHeader.padding(.horizontal,24).padding(.top,notched ? 8 : 18).padding(.bottom,16)
                HStack(spacing: 4) {
                    ForEach(IslandTab.allCases) { item in
                        Button { withAnimation(.easeInOut(duration: 0.16)) { tab = item } } label: {
                            Label(item.rawValue,systemImage: item.icon)
                                .font(.system(size: 12,weight: .medium))
                                .foregroundStyle(tab == item ? .white : .white.opacity(0.45))
                                .frame(maxWidth: .infinity).padding(.vertical,9)
                                .background(tab == item ? Color.white.opacity(0.09) : .clear,in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(4).background(.white.opacity(0.035),in: Capsule()).padding(.horizontal,24)
                Group {
                    switch tab {
                    case .capture: capturePage
                    case .recall: recallPage
                    case .settings: settingsPage
                    }
                }.padding(.horizontal,24).padding(.top,18).frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading)
                HStack(spacing: 5) {
                    Image(systemName: model.audioExport ? "link" : "lock.shield")
                    Text(model.audioExport ? "已允许 Agent 读取原音" : "原音保存在本机")
                    Spacer()
                    Text(model.pinned ? "已固定" : "移开鼠标后收起")
                }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)).padding(.horizontal,26).padding(.top,12).padding(.bottom,18)
            } else { compactHeader }
        }
        .frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .top)
        .background(.black,in: shape)
        .overlay(shape.strokeBorder(.white.opacity(model.expanded ? 0.075 : 0),lineWidth: 1))
        .clipShape(shape)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    private var hardwareHeader: some View {
        HStack {
            LiveAudioGlyph(levels:model.audioLevels,recording:model.recording,size:12).foregroundStyle(accent)
            Spacer(minLength: model.notchWidth)
            Circle().fill(tint).frame(width: 5,height: 5)
        }.padding(.horizontal,26).frame(height: model.notchHeight).accessibilityHidden(true)
    }
    private var compactHeader: some View {
        Button {
            if let onExpand { onExpand() } else { model.expanded = true }
        } label: {
            HStack(spacing: 10) {
                LiveAudioGlyph(levels:model.audioLevels,recording:model.recording,size:15).foregroundStyle(accent)
                if notched { Spacer(minLength: model.notchWidth) }
                else { Text("AgentOne").font(.system(size: 12,weight: .semibold)); Spacer() }
                Circle().fill(tint).frame(width: 5,height: 5)
                if !notched { Text(status).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)) }
            }.padding(.horizontal,20).frame(maxWidth: .infinity,maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("AgentOne，\(status)，展开声音记忆").accessibilityValue(model.recording ? "录音音量 \(Int((model.audioLevels.last ?? 0)*100))%" : model.listening ? "听候中" : "已暂停")
    }
    private var expandedHeader: some View {
        HStack(spacing: 10) {
            LiveAudioGlyph(levels:model.audioLevels,recording:model.recording,size:20).foregroundStyle(accent)
                .frame(width: 38,height: 38).background(accent.opacity(0.1),in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading,spacing: 3) {
                Text("AgentOne").font(.system(size: 15,weight: .semibold))
                Text("声音与事件记忆").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            HStack(spacing: 5) { Circle().fill(tint).frame(width: 5,height: 5); Text(status).font(.system(size: 10)) }
                .foregroundStyle(.white.opacity(0.65)).padding(.horizontal,9).padding(.vertical,6).background(.white.opacity(0.06),in: Capsule())
            Button { model.pinned.toggle() } label: { Image(systemName: model.pinned ? "pin.fill" : "pin").foregroundStyle(model.pinned ? accent : .white.opacity(0.4)) }
                .buttonStyle(.plain).help(model.pinned ? "取消固定" : "固定展开").accessibilityLabel(model.pinned ? "取消固定" : "固定展开")
            Button { model.pinned = false; model.expanded = false } label: { Image(systemName: "chevron.up").foregroundStyle(.white.opacity(0.4)) }
                .buttonStyle(.plain).help("收起").accessibilityLabel("收起灵动岛")
        }
    }
    private var capturePage: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack {
                VStack(alignment: .leading,spacing: 6) {
                    Text(model.recording ? "正在保留今天的声音" : model.listening ? "正在听候新的声音" : model.hasError ? "自动记录需要处理" : "让记忆从这里开始").font(.system(size: 22,weight: .semibold))
                    Text("声音、时间、地点，留给未来的你。").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
            }
            VStack(alignment:.leading,spacing:12) {
                HStack {
                    LiveAudioGlyph(levels:model.audioLevels,recording:model.recording,size:20).foregroundStyle(accent)
                    Text("系统声音 ＋ 麦克风").font(.system(size:13,weight:.medium))
                    Spacer()
                    Text("合并录音").font(.system(size:10)).foregroundStyle(accent)
                }
                Text("保存为一条录音，回放和回忆都在一起。").font(.system(size:11)).foregroundStyle(.white.opacity(0.45))
                if model.listening {
                    HStack(spacing:12) {
                        Label(model.systemReceiving ? "电脑声音已接入" : "等待电脑声音",systemImage:"speaker.wave.2")
                        Label(model.microphoneReceiving ? "麦克风已接入" : "等待麦克风",systemImage:"mic")
                    }.font(.system(size:9)).foregroundStyle(.white.opacity(0.4))
                }
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.055),in:RoundedRectangle(cornerRadius:16))
            HStack {
                Label("地点",systemImage: "mappin.and.ellipse").foregroundStyle(.white.opacity(0.4))
                TextField("添加地点，例如：工位",text: $model.place).textFieldStyle(.plain).onChange(of: model.place) { _,_ in model.updateMetadata() }
            }.font(.system(size: 11)).padding(11).background(.white.opacity(0.045),in: RoundedRectangle(cornerRadius: 10))
            Button { model.toggleRecording() } label: {
                HStack(spacing: 8) { Image(systemName: model.listening ? "pause.fill" : "record.circle"); Text(model.busy ? "正在启动…" : model.listening ? "暂停记录" : model.automaticRecording ? "恢复自动记录" : "开启录音") }
                    .font(.system(size: 13,weight: .semibold)).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical,12)
                    .background(accent,in: Capsule())
            }.buttonStyle(.plain).disabled(model.busy || model.demo)
            Text(model.listening ? model.decisionStatus : model.message).font(.system(size: 10)).foregroundStyle(model.hasError ? .orange : .white.opacity(0.4)).lineLimit(2).fixedSize(horizontal: false,vertical: true)
            Spacer(minLength: 0)
        }
    }
    private var recallPage: some View {
        VStack(spacing:12) {
            HStack(spacing:8) {
                Button {showEvents=false} label: {Text("声音").foregroundStyle(showEvents ? .white.opacity(0.4) : accent)}
                Button {showEvents=true} label: {Text("事件 · \(model.eventCount)").foregroundStyle(showEvents ? accent : .white.opacity(0.4))}
                Spacer()
            }.font(.system(size:11,weight:.medium)).buttonStyle(.plain)
            if showEvents {eventRecallPage} else {audioRecallPage}
        }
    }
    private var eventRecallPage: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {Text("事件记录").font(.system(size:17,weight:.semibold));Spacer();Button("同步旧记录") {model.syncLegacyEvents()}.font(.system(size:10))}
            Text(model.eventImportStatus).font(.system(size:10)).foregroundStyle(.white.opacity(0.4))
            TextField("搜索网页、应用或原话",text:$model.query).textFieldStyle(.plain).font(.system(size:12)).padding(10).background(.white.opacity(0.055),in:RoundedRectangle(cornerRadius:10)).onChange(of:model.query) {_,_ in model.refresh()}
            ScrollView {
                VStack(alignment:.leading,spacing:10) {
                    if model.eventRows.isEmpty {Text("旧 Diary 与新事件会出现在这里；没有权限时只保留应用切换。").font(.system(size:11)).foregroundStyle(.white.opacity(0.4)).padding(.vertical,25)}
                    ForEach(model.eventRows,id: \.["id"]) {row in
                        VStack(alignment:.leading,spacing:6) {
                            HStack {
                                Text(time(row["started_ms"])).monospacedDigit()
                                Text(row["application"] ?? "应用未知").foregroundStyle(.white.opacity(0.45))
                                Spacer()
                                Text(row["provenance"]=="legacy_diary" ? "旧记录" : "现场事件").foregroundStyle(accent.opacity(0.7))
                            }.font(.system(size:9))
                            Text(row["title"] ?? row["kind"] ?? "事件").font(.system(size:12,weight:.medium)).lineLimit(2)
                            Text(row["text"] ?? "").font(.system(size:10)).foregroundStyle(.white.opacity(0.6)).lineLimit(expandedEventID==row["id"] ? nil : 3).textSelection(.enabled)
                            HStack {
                                Button(expandedEventID==row["id"] ? "收起原文" : "展开原文") {expandedEventID=expandedEventID==row["id"] ? nil : row["id"]}
                                Spacer()
                                if row["provenance"]=="legacy_diary" {Button("原记录") {model.openEventSource(row)}}
                            }.font(.system(size:9)).buttonStyle(.plain).foregroundStyle(accent)
                        }.padding(11).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:12))
                    }
                }
            }.frame(maxHeight:.infinity)
        }
    }
    private var audioRecallPage: some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack { Text("最近的声音").font(.system(size: 17,weight: .semibold)); Spacer(); Text("\(model.pending) 项待分析").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.4)); TextField("搜索原话、主题或地点",text: $model.query).textFieldStyle(.plain).onChange(of: model.query) { _,_ in model.refresh() } }
                .font(.system(size: 12)).padding(12).background(.white.opacity(0.055),in: RoundedRectangle(cornerRadius: 12))
            ScrollView {
                VStack(alignment: .leading,spacing: 10) {
                    if model.rows.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.path").font(.system(size: 32,weight: .ultraLight)).foregroundStyle(accent.opacity(0.6))
                            Text("还没有声音片段").font(.system(size: 13,weight: .medium))
                            Text("开启记录后，片段会按时间保存在这里。\n转写完成后，可以按原话和主题找回。").font(.system(size: 11)).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.4))
                        }.frame(maxWidth: .infinity).padding(.vertical,38)
                    }
                    ForEach(model.rows,id: \.["id"]) { row in
                        VStack(alignment: .leading,spacing: 7) {
                            HStack {
                                Text(time(row["started_ms"])).monospacedDigit()
                                Text(row["source"] == "mixed" ? "混合录音" : row["source"] == "microphone" ? "历史麦克风" : "历史系统音").foregroundStyle(.white.opacity(0.4))
                                if let place = row["place"], !place.isEmpty { Text(place).foregroundStyle(.white.opacity(0.4)) }
                                Spacer()
                                if row["state"] == "sealed" { Button("原音") { model.openAudio(row) }.buttonStyle(.plain).foregroundStyle(accent) }
                            }.font(.system(size: 10))
                            Text(row["text"].flatMap { $0.isEmpty ? nil : $0 } ?? (row["state"] == "incomplete" ? "末段不完整，保留待恢复" : "等待转写")).font(.system(size: 12)).lineLimit(3)
                            if let payload = row["payload_json"],let data = payload.data(using: .utf8),let value = try? JSONSerialization.jsonObject(with: data) as? [String:Any],let tags = value["tags"] as? [String] {
                                Text(tags.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(accent.opacity(0.7))
                            }
                        }.padding(12).background(.white.opacity(0.05),in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.frame(maxHeight: .infinity)
        }
    }
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 16) {
                Text("记录偏好").font(.system(size: 17,weight: .semibold))
                VStack(alignment: .leading,spacing: 14) {
                    Toggle("记录应用、网页和交互事件",isOn:Binding(get:{model.eventCaptureEnabled},set:{model.setEventCapture($0)}))
                    Text(model.eventCaptureStatus).font(.system(size:10)).foregroundStyle(.white.opacity(0.4))
                    Button("检查事件详情权限") {model.eventService?.requestDetailsPermission()}.font(.system(size:10))
                    Toggle("自动记录声音",isOn: Binding(get: {model.automaticRecording},set: {model.setAutomaticRecording($0)}))
                    Text("Laya 在本机判断录音或听候；听候只保留 10 秒内存预录。判断失败时保留声音，手动暂停后保持暂停。").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    Toggle("登录后自动启动",isOn: Binding(get: {model.autoResume},set: {model.setAutoResume($0)}))
                    HStack {
                        Text(model.loginStatus).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        if model.autoResume { Button("系统设置") { model.openLoginSettings() }.font(.system(size: 10)) }
                    }
                    Toggle("锁屏时暂停",isOn: $model.pauseOnLock).onChange(of: model.pauseOnLock) { _,value in UserDefaults.standard.set(value,forKey: "vNext.pauseOnLock") }
                    Text("关闭锁屏暂停后，将尽量持续记录；休眠时仍会暂停。").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    Divider().overlay(.white.opacity(0.08))
                    HStack { VStack(alignment: .leading,spacing: 4) { Text("本机转写"); Text(model.asrStatus).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }; Spacer(); if !model.localASR { Button("启用") { model.enableASR() } } }
                    Toggle("允许 Agent 读取原音",isOn: Binding(get: {model.audioExport},set: {model.setAudioExport($0)}))
                    Text("开启后，连接的 Agent 可以通过 MCP 读取音频，宿主可能使用云模型。").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }.font(.system(size: 12)).toggleStyle(.switch).tint(accent).disabled(model.demo)
                Divider()
                HStack { Button("打开 Memory 文件夹") { if let root = model.database?.root { NSWorkspace.shared.open(root) } }; Spacer(); Button("删除最近片段",role: .destructive) { model.deleteRecent() }.disabled(model.rows.isEmpty) }.font(.system(size: 10))
                Text("查找线索、提取长期记忆和执行待办，由你连接的 Agent 完成。").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }.padding(.bottom,6)
        }
    }
    private func time(_ value: String?) -> String {
        guard let value,let ms = Double(value) else { return "未知时间" }
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
private enum IslandTab: String,CaseIterable,Identifiable {
    case capture = "记录", recall = "回忆", settings = "设置"
    var id: Self { self }
    var icon: String { switch self { case .capture: "waveform"; case .recall: "clock.arrow.circlepath"; case .settings: "slider.horizontal.3" } }
}
