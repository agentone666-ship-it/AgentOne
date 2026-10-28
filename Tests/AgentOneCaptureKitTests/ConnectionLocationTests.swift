@testable import AgentOneCaptureKit
import Foundation
import Testing

struct ConnectionLocationTests {
    private var repo:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()}
    @Test func rejectsInvalidStaleAndFutureLocationWithoutGuessingPlace() throws {
        let now=Date()
        #expect(LocationObservation(latitude:.nan,longitude:0,horizontalAccuracy:1,observedAt:now)==nil)
        #expect(LocationObservation(latitude:91,longitude:0,horizontalAccuracy:1,observedAt:now)==nil)
        #expect(LocationObservation(latitude:0,longitude:181,horizontalAccuracy:1,observedAt:now)==nil)
        #expect(LocationObservation(latitude:0,longitude:0,horizontalAccuracy:-1,observedAt:now)==nil)
        #expect(LocationObservation(latitude:0,longitude:0,horizontalAccuracy:5001,observedAt:now)==nil)
        let old=try #require(LocationObservation(latitude:31,longitude:121,horizontalAccuracy:100,observedAt:now.addingTimeInterval(-601),label:"过期位置"))
        #expect(!old.isFresh(at:now))
        let future=try #require(LocationObservation(latitude:31,longitude:121,horizontalAccuracy:100,observedAt:now.addingTimeInterval(60)))
        #expect(!future.isFresh(at:now))
        let metadata=CaptureMetadata()
        metadata.update(place:old.displayName,application:"fixture",bundleID:nil,location:old)
        let snapshot=metadata.snapshot();#expect(snapshot.0==nil)
        let json=try #require(JSONSerialization.jsonObject(with:Data(snapshot.1.utf8)) as? [String:Any])
        #expect(json["place_source"] as? String=="unknown");#expect(json["location"]==nil)
    }
    @Test func preservesSystemLocationPrecisionTimeAndSourceSeparatelyFromUserLabels() throws {
        let point=try #require(LocationObservation(latitude:31.2,longitude:121.5,horizontalAccuracy:75,observedAt:Date(),label:"合成城市 · 合成街道"))
        let metadata=CaptureMetadata();metadata.update(place:point.displayName,application:"fixture",bundleID:nil,location:point)
        let json=try #require(JSONSerialization.jsonObject(with:Data(metadata.snapshot().1.utf8)) as? [String:Any])
        #expect(metadata.snapshot().0==point.displayName);#expect(json["place_source"] as? String=="core_location")
        let location=try #require(json["location"] as? [String:Any]);#expect(location["horizontal_accuracy_m"] as? Double==75);#expect(location["latitude"] as? Double==31.2);#expect(location["observed_at"] as? String != nil)
        metadata.update(place:nil,application:"fixture",bundleID:nil)
        #expect(metadata.snapshot().0==nil)
        #expect(!metadata.snapshot().1.contains("latitude"))
        metadata.update(place:"历史标注",application:nil,bundleID:nil)
        #expect(metadata.snapshot().1.contains("user_annotation"))
    }
    @Test func exportsRelocatablePluginWithRealMCPAndNoUserData() async throws {
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("plugin-export-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temporary)}
        let memory=temporary.appendingPathComponent("Private Memory")
        let db=try MemoryDatabase(root:memory)
        let node=try #require(AgentConnectionPackage.findNode())
        let package=AgentConnectionPackage(resources:repo.appendingPathComponent("plugins/agentone-memory"),memoryRoot:memory,node:node)
        let root=try package.export(to:temporary.appendingPathComponent("Output With Spaces")),plugin=root.appendingPathComponent("agentone-memory")
        #expect(!FileManager.default.fileExists(atPath:plugin.appendingPathComponent("memory.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath:plugin.appendingPathComponent("Audio").path))
        let config=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:plugin.appendingPathComponent("mcp.json"))) as? [String:Any])
        let servers=try #require(config["mcpServers"] as? [String:[String:Any]]),server=try #require(servers["agentone-memory"])
        #expect(server["args"] as? [String]==["${PLUGIN_ROOT}/server.mjs"])
        #expect((server["env"] as? [String:String])?["AGENTONE_MEMORY_HOME"]==memory.path)
        let moved=temporary.appendingPathComponent("Moved Plugin")
        try FileManager.default.moveItem(at:plugin,to:moved)
        let installed=AgentConnectionPackage(resources:moved,memoryRoot:memory,node:node)
        let count=try await Task.detached {try installed.connectionCheck()}.value
        #expect(count==11)
        #expect(try db.rows("SELECT * FROM meta WHERE key='last_agent_connection'").isEmpty)
        #expect(try db.rows("SELECT * FROM segments").isEmpty)
    }
}

import AVFoundation
import CoreMedia

struct LocationAudioPersistenceTests {
    @Test func addressResolutionCanRefineTheSameFixWithoutChangingItsTime() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let db=try MemoryDatabase(root:root),metadata=CaptureMetadata(),wall=Date(),host=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        var fix=try #require(LocationObservation(latitude:31,longitude:121,horizontalAccuracy:50,observedAt:wall))
        metadata.update(place:fix.displayName,application:nil,bundleID:nil,location:fix)
        let writer=AudioTrackWriter(database:db,source:"mixed",sessionID:"address-refinement",wallAnchor:wall,hostAnchor:host,metadata:{metadata.snapshot()})
        let format=try #require(AVAudioFormat(standardFormatWithSampleRate:48000,channels:1))
        let buffer=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800));buffer.frameLength=4800
        buffer.floatChannelData![0].update(repeating:0,count:4800)
        try writer.append(buffer,presentationSeconds:host)
        fix.label="合成城市 · 合成街道";metadata.update(place:fix.displayName,application:nil,bundleID:nil,location:fix)
        try writer.finish()
        let row=try #require(db.rows("SELECT * FROM segments").first)
        #expect(row["place"]==fix.displayName)
        #expect(row["context_json"]?.contains("horizontal_accuracy_m")==true)
    }
    @Test func fixArrivingDuringRecordingIsSavedButLaterFixIsNotBackdated() throws {
        for seconds in [0.5,8.0] {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer {try? FileManager.default.removeItem(at:root)}
            let db=try MemoryDatabase(root:root),metadata=CaptureMetadata(),wall=Date(),host=CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            metadata.update(place:nil,application:"fixture",bundleID:nil)
            let writer=AudioTrackWriter(database:db,source:"mixed",sessionID:"location-fixture",wallAnchor:wall,hostAnchor:host,metadata:{metadata.snapshot()})
            let format=try #require(AVAudioFormat(standardFormatWithSampleRate:48000,channels:1))
            let buffer=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000));buffer.frameLength=48000
            buffer.floatChannelData![0].update(repeating:0,count:48000)
            try writer.append(buffer,presentationSeconds:host)
            let location=try #require(LocationObservation(latitude:31,longitude:121,horizontalAccuracy:50,observedAt:wall.addingTimeInterval(seconds),label:"合成地点"))
            metadata.update(place:location.displayName,application:"fixture",bundleID:nil,location:location)
            try writer.finish()
            let row=try #require(db.rows("SELECT * FROM segments").first)
            if seconds<1 {
                #expect(row["place"]=="合成地点")
                #expect(row["context_json"]?.contains("sampled_during_segment")==true)
                #expect(row["context_json"]?.contains("horizontal_accuracy_m")==true)
            } else {
                #expect(row["place"]==nil)
                #expect(row["context_json"]?.contains("latitude")==false)
            }
        }
    }
}
