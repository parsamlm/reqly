import BodyKit
import Foundation
import Presentation
import Testing

@Suite struct ProtobufFilesTests {
    let folder = URL.temporaryDirectory.appending(path: "ReqlyProtoTests-\(UUID().uuidString)")

    func write(_ text: String, to path: String) throws -> URL {
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    @Test func readsFilesAndFoldersAndSaysWhatItCouldnt() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try write(
            """
            syntax = "proto3";
            package weather.v1;
            import "weather/v1/common.proto";
            message Forecast { City city = 1; repeated Hour hours = 2; }
            message Hour { int32 hour = 1; }
            service Forecasts { rpc Get(City) returns (Forecast); }
            """, to: "protos/weather/v1/forecast.proto")
        _ = try write(
            """
            syntax = "proto3";
            package weather.v1;
            message City { string name = 1; }
            """, to: "protos/weather/v1/common.proto")
        _ = try write("not a .proto file", to: "protos/notes.txt")
        let single = try write("syntax = \"proto3\";\nmessage Alone { bool ok = 1 }\n", to: "alone.proto")
        let binary = folder.appending(path: "binary.proto")
        try Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: binary)

        let sources = [
            ProtobufFiles.Source(folder.appending(path: "protos")), ProtobufFiles.Source(single),
            ProtobufFiles.Source(binary),
            ProtobufFiles.Source(path: folder.appending(path: "gone").path, isFolder: true),
        ]
        #expect(sources[0].isFolder && !sources[1].isFolder)
        let reading = ProtobufFiles.read(sources)
        #expect(reading.counts[sources[0].id] == 2 && reading.counts[sources[1].id] == 1)
        #expect(reading.counts[sources[3].id] == nil)
        #expect(reading.schema.message(named: "weather.v1.Forecast") != nil)
        #expect(reading.schema.method(forPath: "/weather.v1.Forecasts/Get")?.output == "weather.v1.Forecast")
        let problems = reading.problems.map { "\($0.file):\($0.line) \($0.message)" }
        #expect(problems.contains("binary.proto:0 Reqly can't read this file as text."))
        #expect(problems.contains("gone:0 Reqly can't find this anymore. It may have been moved or deleted."))
        // The file without a semicolon is the files' own problem, with its line.
        #expect(reading.problems.contains { $0.file == "alone.proto" && $0.line == 2 })
        #expect(ProtobufFiles.summary(reading.schema, hasSources: true) == "3 message types and 1 service.")
        #expect(ProtobufFiles.summary(ProtobufSchema(), hasSources: true) == "These files have no message types yet.")
        #expect(ProtobufFiles.summary(ProtobufSchema(), hasSources: false) == "")
    }

    @Test func keepsTheListAndTheTypesChosen() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Protobuf.json")
        #expect(ProtobufFiles.load(from: file) == ProtobufFiles.Contents())
        let contents = ProtobufFiles.Contents(
            sources: [ProtobufFiles.Source(path: "/protos", isFolder: true)],
            chosenTypes: [
                ProtobufFiles.key(
                    for: URL(string: "https://api.weatherly.dev:8443/v1/fore%20cast?days=3"), isRequest: false):
                    "weather.v1.Forecast"
            ])
        try ProtobufFiles.save(contents, to: file)
        #expect(ProtobufFiles.load(from: file) == contents)
        #expect(contents.chosenTypes.keys.first == "api.weatherly.dev/v1/fore cast response")
        try Data("not json".utf8).write(to: file)
        #expect(ProtobufFiles.load(from: file) == ProtobufFiles.Contents())
    }
}
