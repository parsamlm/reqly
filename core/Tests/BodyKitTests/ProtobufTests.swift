import Foundation
import Testing

@testable import BodyKit

/// Builds protobuf bytes for the tests, field by field.
struct ProtoWriter {
    var bytes: [UInt8] = []

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    mutating func varint(_ number: Int, _ value: UInt64) {
        bytes += Self.varint(UInt64(number << 3)) + Self.varint(value)
    }

    mutating func fixed32(_ number: Int, _ value: UInt32) {
        bytes += Self.varint(UInt64(number << 3 | 5)) + (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) }
    }

    mutating func fixed64(_ number: Int, _ value: UInt64) {
        bytes += Self.varint(UInt64(number << 3 | 1)) + (0..<8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) }
    }

    mutating func bytes(_ number: Int, _ value: [UInt8]) {
        bytes += Self.varint(UInt64(number << 3 | 2)) + Self.varint(UInt64(value.count)) + value
    }

    mutating func string(_ number: Int, _ value: String) {
        bytes(number, Array(value.utf8))
    }

    mutating func message(_ number: Int, _ build: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        build(&nested)
        bytes(number, nested.bytes)
    }

    var data: Data { Data(bytes) }
}

@Suite struct ProtobufTests {
    @Test func readsFieldsWithoutASchema() throws {
        var writer = ProtoWriter()
        writer.string(1, "Amsterdam")
        writer.fixed32(2, Float(14.2).bitPattern)
        writer.message(3) {
            $0.varint(1, 1_696_000_000)
            $0.varint(2, 1)
        }
        writer.varint(4, 1)
        writer.varint(4, 2)
        writer.bytes(5, [0x00, 0xFF, 0x10])
        writer.fixed64(6, Double(3.5).bitPattern)
        writer.varint(7, UInt64(bitPattern: -1))
        writer.fixed32(8, 1_696_000_000)
        let message = try #require(Protobuf.decode(writer.data))
        #expect(message.fields.map(\.number) == [1, 2, 3, 4, 4, 5, 6, 7, 8])
        #expect(
            message.formatted().text == """
                1: "Amsterdam"
                2: 14.2
                3 {
                  1: 1696000000
                  2: 1
                }
                4: 1
                4: 2
                5: "\\x00\\xff\\x10"
                6: 3.5
                7: -1
                8: 1696000000

                """)
        #expect(message.fields[2].typeName == "message")
        #expect(message.fields[5].typeName == "bytes")
    }

    @Test func readsTextAsTextUnlessItStartsLikeAMessage() throws {
        var writer = ProtoWriter()
        // "hi" also parses as field 13 holding 105.
        writer.string(1, "hi")
        // A message whose first field is a string starts with a line feed, which is text too.
        writer.message(2) { $0.string(1, String(repeating: "x", count: 40)) }
        writer.string(3, "")
        let message = try #require(Protobuf.decode(writer.data))
        #expect(message.fields[0].value == .string("hi"))
        #expect(message.fields[1].value.message?.fields.first?.value == .string(String(repeating: "x", count: 40)))
        #expect(message.fields[2].value == .string(""))
    }

    @Test func rejectsWhatIsNotProtobuf() {
        // Longer than what's there.
        #expect(Protobuf.decode(Data([0x0A, 0x05, 0x61])) == nil)
        // Wire type 7, and field number 0.
        #expect(Protobuf.decode(Data([0x0F, 0x01])) == nil)
        #expect(Protobuf.decode(Data([0x00, 0x01])) == nil)
        // A varint that never ends.
        #expect(Protobuf.decode(Data([0x08] + Array(repeating: 0xFF, count: 11))) == nil)
        #expect(Protobuf.decode(Data("{\"city\": \"Amsterdam\"}".utf8)) == nil)
        #expect(Protobuf.decode(Data())?.fields.isEmpty == true)
    }

    @Test func readsGroups() throws {
        // Field 1 is a group holding field 2, then field 3 follows.
        let bytes: [UInt8] = [0x0B, 0x10, 0x05, 0x0C, 0x18, 0x07]
        let message = try #require(Protobuf.decode(Data(bytes)))
        #expect(message.fields.count == 2)
        #expect(
            message.fields[0].value == .group(ProtobufMessage(fields: [ProtobufField(number: 2, value: .varint(5))])))
        #expect(message.formatted().text == "1 {\n  2: 5\n}\n3: 7\n")
        // An end marker for another group.
        #expect(Protobuf.decode(Data([0x0B, 0x10, 0x05, 0x14])) == nil)
    }

    @Test func stopsAtTheDeepestNesting() throws {
        var bytes: [UInt8] = [0x08, 0x01]
        for _ in 0..<200 {
            bytes = [0x0A] + ProtoWriter.varint(UInt64(bytes.count)) + bytes
        }
        let message = try #require(Protobuf.decode(Data(bytes)))
        var depth = 0
        var current = message
        while let nested = current.fields.first?.value.message {
            depth += 1
            current = nested
        }
        #expect(depth < Protobuf.maximumDepth)
        // What's deeper shows as bytes.
        if case .bytes = current.fields.first?.value {
        } else {
            Issue.record("Expected bytes past the deepest level, got \(String(describing: current.fields.first))")
        }
        _ = message.formatted()
        _ = ProtobufTree(message, rootLabel: "Response")
    }
}

@Suite struct ProtoFileTests {
    static let weather = """
        syntax = "proto3";
        package weather.v1;

        import "google/protobuf/timestamp.proto";
        option java_package = "dev.weatherly.v1";

        // The forecast for a city.
        message Forecast {
          string city = 1;
          float temperature = 2;
          repeated Hour hourly = 3;
          Condition condition = 4;
          map<string, int32> counts = 5;
          google.protobuf.Timestamp issued = 6;
          repeated int32 codes = 7;
          sint32 offset = 8;
          oneof source {
            string station = 9;
            Station station_info = 10;
          }
          reserved 11 to 15, 20;
          reserved "old_name";

          /* An hour of it. */
          message Hour {
            int64 time = 1;
            double rain = 2 [deprecated = true, json_name = "rainMM"];
          }
        }

        message Station { string id = 1; }

        enum Condition {
          option allow_alias = true;
          CONDITION_UNSPECIFIED = 0;
          SUNNY = 1;
          RAINY = 2;
          WET = 2;
        }

        service Forecasts {
          rpc Get (GetRequest) returns (Forecast);
          rpc Watch (stream GetRequest) returns (stream Forecast) {
            option (google.api.http) = { get: "/v1/watch" };
          }
        }

        message GetRequest { string city = 1; }
        """

    static func forecast() -> ProtoWriter {
        var writer = ProtoWriter()
        writer.string(1, "Amsterdam")
        writer.fixed32(2, Float(14.2).bitPattern)
        writer.message(3) {
            $0.varint(1, 1)
            $0.fixed64(2, Double(0.5).bitPattern)
        }
        writer.message(3) { $0.varint(1, 2) }
        writer.varint(4, 2)
        writer.message(5) {
            $0.string(1, "a")
            $0.varint(2, 1)
        }
        writer.message(6) { $0.varint(1, 1_759_489_200) }
        // Packed, as proto3 sends repeated numbers.
        writer.bytes(7, ProtoWriter.varint(1) + ProtoWriter.varint(2) + ProtoWriter.varint(300))
        writer.varint(8, 5)
        return writer
    }

    @Test func readsTheTypesOfAFile() throws {
        let (schema, problems) = ProtobufSchema.load([("weather.proto", Self.weather)])
        #expect(problems.isEmpty)
        let forecast = try #require(schema.message(named: "weather.v1.Forecast"))
        #expect(forecast.fields[3]?.type == .message("weather.v1.Forecast.Hour"))
        #expect(forecast.fields[3]?.isRepeated == true)
        #expect(forecast.fields[4]?.type == .enumeration("weather.v1.Condition"))
        #expect(forecast.fields[5]?.type == .message("weather.v1.Forecast.CountsEntry"))
        #expect(schema.message(named: ".weather.v1.Forecast.CountsEntry")?.isMapEntry == true)
        #expect(forecast.fields[6]?.type == .message("google.protobuf.Timestamp"))
        #expect(forecast.fields[10]?.type == .message("weather.v1.Station"))
        #expect(schema.enums["weather.v1.Condition"]?.names[2] == "RAINY")
        #expect(
            schema.messageNames == [
                "weather.v1.Forecast", "weather.v1.Forecast.Hour", "weather.v1.GetRequest", "weather.v1.Station",
            ])
        #expect(ProtobufSchema.load([]).schema.messageNames.isEmpty)
        #expect(ProtobufSchema.load([]).schema.message(named: "google.protobuf.Timestamp") != nil)

        let get = try #require(schema.method(forPath: "/weather.v1.Forecasts/Get"))
        #expect(get.input == "weather.v1.GetRequest")
        #expect(get.output == "weather.v1.Forecast")
        let watch = try #require(schema.method(forPath: "/api/weather.v1.Forecasts/Watch"))
        #expect(watch.clientStreams && watch.serverStreams)
        #expect(schema.method(forPath: "/weather.v1.Forecasts/Delete") == nil)
    }

    @Test func readsAMessageWithItsSchema() throws {
        let schema = ProtobufSchema.load([("weather.proto", Self.weather)]).schema
        let message = try #require(Protobuf.decode(Self.forecast().data, as: "weather.v1.Forecast", schema: schema))
        #expect(message.typeName == "weather.v1.Forecast")
        #expect(
            message.formatted().text == """
                city: "Amsterdam"
                temperature: 14.2
                hourly {
                  time: 1
                  rain: 0.5
                }
                hourly {
                  time: 2
                }
                condition: RAINY
                counts {
                  key: "a"
                  value: 1
                }
                issued {
                  seconds: 1759489200
                }
                codes: 1
                codes: 2
                codes: 300
                offset: -3

                """)

        let tree = ProtobufTree(message, rootLabel: "Response")
        let root = tree.node(0)
        #expect(root.typeName == "Forecast")
        #expect(root.summary == "11 fields")
        let labels = root.children.map { tree.node($0).label }
        #expect(labels == ["city", "temperature", "hourly", "condition", "counts", "issued", "codes", "offset"])
        func child(_ label: String, of id: Int = 0) throws -> Int {
            try #require(tree.node(id).children.first { tree.node($0).label == label })
        }
        let hourly = try child("hourly")
        #expect(tree.node(hourly).summary == "2 items")
        let time = try child("time", of: tree.node(hourly).children[0])
        #expect(tree.path(to: time) == "hourly[0].time")
        #expect(tree.node(time).typeName == "int64")
        #expect(tree.node(try child("condition")).summary == "RAINY")
        let counts = try child("counts")
        #expect(tree.node(counts).summary == "1 entry")
        let entry = tree.node(counts).children[0]
        #expect(tree.node(entry).label == "\"a\"")
        #expect(tree.node(entry).summary == "1")
        #expect(tree.path(to: entry) == "counts[\"a\"]")
        #expect(tree.node(try child("issued")).summary == "2025-10-03T11:00:00Z")
        #expect(tree.node(try child("codes")).summary == "3 items")
        #expect(tree.copyText(of: try child("city")) == "Amsterdam")
        #expect(tree.copyText(of: tree.node(hourly).children[1]) == "time: 2\n")
    }

    @Test func readsFieldsTheSchemaDoesNotKnowByNumber() throws {
        let schema = ProtobufSchema.load([("weather.proto", Self.weather)]).schema
        var writer = ProtoWriter()
        writer.string(1, "Amsterdam")
        writer.varint(99, 7)
        // A string where the schema says a float: read as without a schema.
        writer.string(2, "warm")
        let message = try #require(Protobuf.decode(writer.data, as: "weather.v1.Forecast", schema: schema))
        #expect(message.formatted().text == "city: \"Amsterdam\"\n99: 7\n2: \"warm\"\n")
    }

    @Test func readsTheMessageInsideAnAny() throws {
        let file = """
            syntax = "proto3";
            package box;
            import "google/protobuf/any.proto";
            message Box { google.protobuf.Any content = 1; }
            message Note { string text = 1; }
            """
        let schema = ProtobufSchema.load([("box.proto", file)]).schema
        var writer = ProtoWriter()
        writer.message(1) {
            $0.string(1, "type.googleapis.com/box.Note")
            $0.message(2) { $0.string(1, "hello") }
        }
        let message = try #require(Protobuf.decode(writer.data, as: "box.Box", schema: schema))
        #expect(
            message.formatted().text == """
                content {
                  type_url: "type.googleapis.com/box.Note"
                  value {
                    text: "hello"
                  }
                }

                """)
    }

    @Test func reportsWhatItCannotUse() {
        let unknownType = """
            syntax = "proto3";
            message Forecast {
              string city = 1;
              Missing thing = 2;
            }
            """
        let (schema, problems) = ProtobufSchema.load([("a.proto", unknownType), ("b.proto", "message {")])
        #expect(problems.count == 2)
        #expect(problems.first == ProtoFileProblem(file: "a.proto", line: 4, message: problems.first?.message ?? ""))
        #expect(problems.first?.message.contains("Missing") == true)
        #expect(problems.last?.file == "b.proto")
        #expect(problems.last?.line == 1)
        // The rest of the file still counts.
        #expect(schema.message(named: "Forecast")?.fields[1]?.name == "city")
        #expect(schema.message(named: "Forecast")?.fields[2] == nil)

        let twice = ProtobufSchema.load([("a.proto", "message A {}"), ("b.proto", "message A {}")]).problems
        #expect(twice.map(\.file) == ["b.proto"])
        // Files may have their own copies of the well-known types.
        let wellKnown = "syntax = \"proto3\"; package google.protobuf; message Timestamp { int64 seconds = 1; }"
        #expect(ProtobufSchema.load([("timestamp.proto", wellKnown)]).problems.isEmpty)
    }

    @Test func readsProto2Files() throws {
        let file = """
            syntax = "proto2";
            package legacy;
            message Search {
              required string query = 1;
              optional int32 page = 2 [default = 1];
              repeated group Result = 3 {
                required string url = 4;
              }
              extensions 100 to 199;
            }
            extend Search { optional bool fast = 100; }
            """
        let (schema, problems) = ProtobufSchema.load([("legacy.proto", file)])
        #expect(problems.isEmpty)
        let search = try #require(schema.message(named: "legacy.Search"))
        #expect(search.fields[3]?.isGroup == true)
        #expect(search.fields[3]?.name == "result")
        #expect(search.fields[100]?.name == "[legacy.fast]")
        // query "x", a result group holding url "u", and the extension.
        let bytes: [UInt8] = [0x0A, 0x01, 0x78, 0x1B, 0x22, 0x01, 0x75, 0x1C, 0xA0, 0x06, 0x01]
        let message = try #require(Protobuf.decode(Data(bytes), as: "legacy.Search", schema: schema))
        #expect(message.formatted().text == "query: \"x\"\nresult {\n  url: \"u\"\n}\n[legacy.fast]: true\n")
    }
}

@Suite struct GRPCTests {
    static func frame(_ payload: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        let length = payload.count
        return [
            flags, UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF),
            UInt8(length & 0xFF),
        ]
            + payload
    }

    let amsterdam: [UInt8] = [0x0A, 0x09] + Array("Amsterdam".utf8)
    let gzippedAmsterdam: [UInt8] = [
        31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 227, 226, 116, 204, 45, 46, 73, 45, 74, 73, 204, 5, 0, 56, 81, 214, 42, 11,
        0, 0, 0,
    ]

    @Test func readsMessagesOneAfterAnother() {
        let data = Data(Self.frame(amsterdam) + Self.frame(gzippedAmsterdam, flags: 1) + [0, 0, 0])
        let body = GRPCBody.read(data, framing: .grpc, encoding: "gzip")
        #expect(body.messages.map(\.data) == [Data(amsterdam), Data(amsterdam)])
        #expect(body.messages.map(\.wasCompressed) == [false, true])
        #expect(body.messages[1].wireSize == gzippedAmsterdam.count)
        // The start of a message that hasn't come yet.
        #expect(body.incompleteBytes == 3)
        #expect(body.problem == nil)

        let snappy = GRPCBody.read(Data(Self.frame([1, 2], flags: 1)), framing: .grpc, encoding: "snappy")
        #expect(snappy.messages.map(\.data) == [Data([1, 2])])
        #expect(snappy.problem?.contains("snappy") == true)
    }

    @Test func readsTheStatusAtTheEndOfAGRPCWebResponse() {
        let status = Array("grpc-status: 5\r\ngrpc-message: No%20such%20city\r\n".utf8)
        let bytes = Self.frame(amsterdam) + Self.frame(status, flags: 0x80)
        let body = GRPCBody.read(Data(bytes), framing: .grpcWeb, encoding: nil)
        #expect(body.messages.map(\.data) == [Data(amsterdam)])
        #expect(
            body.trailers == [
                .init(name: "grpc-status", value: "5"), .init(name: "grpc-message", value: "No%20such%20city"),
            ])

        // As text, each part may be its own piece of base64.
        let text =
            Data(Self.frame(amsterdam)).base64EncodedString()
            + Data(Self.frame(status, flags: 0x80)).base64EncodedString()
        let fromText = GRPCBody.read(Data(text.utf8), framing: .grpcWebText, encoding: nil)
        #expect(fromText == body)
    }

    @Test func recognizesGRPCAndProtobufBodies() {
        #expect(BodyKind.detect(Data(), contentType: "application/grpc") == .grpc(.grpc))
        #expect(BodyKind.detect(Data(), contentType: "application/grpc+proto") == .grpc(.grpc))
        #expect(BodyKind.detect(Data(), contentType: "application/grpc+json") == .grpc(.grpc))
        #expect(GRPCFraming.carriesJSON("application/grpc+json"))
        #expect(BodyKind.detect(Data(), contentType: "application/grpc-web+proto") == .grpc(.grpcWeb))
        #expect(BodyKind.detect(Data(), contentType: "application/grpc-web-text") == .grpc(.grpcWebText))
        #expect(BodyKind.detect(Data(), contentType: "application/connect+proto") == .grpc(.connect))
        #expect(BodyKind.detect(Data(), contentType: "application/x-protobuf") == .protobuf)
        #expect(BodyKind.detect(Data(), contentType: "application/proto") == .protobuf)
        #expect(
            BodyKind.protobufMessageType("application/x-protobuf; messageType=\"weather.v1.Forecast\"")
                == "weather.v1.Forecast")
        #expect(BodyKind.protobufMessageType("application/x-protobuf") == nil)
    }
}
