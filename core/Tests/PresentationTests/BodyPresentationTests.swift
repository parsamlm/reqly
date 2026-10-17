import BodyKit
import Foundation
import Presentation
import ReqlyModel
import Testing

@Suite struct BodyPresentationTests {
    static let weather = """
        syntax = "proto3";
        package weather.v1;

        message Forecast { string city = 1; float temperature = 2; }
        message GetRequest { string city = 1; }

        service Forecasts {
          rpc Get (GetRequest) returns (Forecast);
        }
        """

    /// A protobuf message with field 1 set to "Amsterdam", which reads as either message type.
    static let amsterdam: [UInt8] = [0x0A, 0x09] + Array("Amsterdam".utf8)

    func present(
        _ data: Data, _ contentType: String?, encoding: String? = nil, protobuf: ProtobufReading? = nil
    ) -> BodyPresentation {
        var fields: [HeaderField] = []
        if let contentType {
            fields.append(HeaderField(name: "Content-Type", value: contentType))
        }
        if let encoding {
            fields.append(HeaderField(name: "Content-Encoding", value: encoding))
        }
        return BodyPresentation(data: data, headers: Headers(fields), rootLabel: "Response", protobuf: protobuf)
    }

    func present(_ text: String, _ contentType: String?) -> BodyPresentation {
        present(Data(text.utf8), contentType)
    }

    static func frame(_ payload: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        let length = payload.count
        return [
            flags, UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF),
            UInt8(length & 0xFF),
        ] + payload
    }

    @Test func offersFormattedTreeAndRawJSON() throws {
        let body = present(#"{"city":"Tehran","hours":[11,12]}"#, "application/json")
        #expect(body.kind == .json)
        #expect(body.modes == [.formatted, .tree, .raw, .hex])
        let formatted = try #require(body.formatted)
        #expect(formatted.text.contains("\n"))
        #expect(formatted.rowCount > 1)
        #expect(body.tree != nil)
        #expect(body.raw?.tokens.isEmpty == false)
        #expect(body.note == nil)
        #expect(body.copyableText(in: .formatted) == formatted.text)
        #expect(body.copyableText(in: .raw) == #"{"city":"Tehran","hours":[11,12]}"#)
        #expect(body.copyableText(in: .hex) == nil)
    }

    @Test func saysWhyJSONIsShownRaw() {
        let body = present(#"{"city":"#, "application/json")
        #expect(body.note?.hasPrefix("This isn't valid JSON") == true)
        #expect(body.modes == [.raw, .hex])
    }

    @Test func unpacksCompressedBodies() {
        let gzipped: [UInt8] = [
            31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 227, 226, 116, 204, 45, 46, 73, 45, 74, 73, 204, 5, 0, 56, 81, 214, 42,
            11, 0, 0, 0,
        ]
        let body = present(Data(gzipped), "application/octet-stream", encoding: "gzip")
        #expect(body.unpackedFrom == "gzip")
        #expect(body.content == Data(Self.amsterdam))
        #expect(body.wireSize == gzipped.count)

        // Bytes that aren't gzip show as they came, with a note.
        let broken = present(Data("plain".utf8), "text/plain", encoding: "gzip")
        #expect(broken.kind == .binary)
        #expect(broken.modes == [.hex])
        #expect(broken.unpackedFrom == nil)
        #expect(broken.note?.contains("can't unpack gzip") == true)
        // Identity means not packed at all.
        #expect(present(Data("plain".utf8), "text/plain", encoding: "identity").note == nil)
    }

    @Test func showsEachKindItsOwnWays() {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let png = present(Data(signature + Array(repeating: 0, count: 24)), "image/png")
        #expect(png.kind == .image(.png))
        #expect(png.modes == [.preview, .hex])

        let form = present("city=Tehran&days=3", "application/x-www-form-urlencoded")
        #expect(form.modes == [.form, .raw, .hex])
        #expect(form.fields?.count == 2)
        #expect(form.raw?.isCode == false)

        let xml = present("<a><b>1</b></a>", "application/xml")
        #expect(xml.modes == [.formatted, .raw, .hex])
        #expect(xml.formatted?.text != xml.raw?.text)

        #expect(present("<html><body>Hi</body></html>", "text/html").modes == [.raw, .hex])

        let text = present("Hello", "text/plain")
        #expect(text.modes == [.raw, .hex])
        #expect(text.raw?.isCode == false)

        let binary = present(Data([0, 1, 2, 255, 254]), "application/octet-stream")
        #expect(binary.kind == .binary)
        #expect(binary.modes == [.hex])
    }

    @Test func countsTheRowsTextTakes() {
        // Code keeps its lines whole.
        #expect(BodyPresentation.Code("a\nb").rowCount == 2)
        // Plain text wraps about every hundred characters.
        #expect(BodyPresentation.Code(String(repeating: "x", count: 250), isCode: false).rowCount == 3)
        #expect(BodyPresentation.Code("", isCode: false).rowCount == 1)
    }

    @Test func showsTheStartOfAHugeBody() {
        let body = present(Data(repeating: UInt8(ascii: "a"), count: BodyPresentation.displayLimit + 5), "text/plain")
        #expect(body.isTruncated)
        #expect(body.raw?.text.utf8.count == BodyPresentation.displayLimit)
        #expect(body.content.count == BodyPresentation.displayLimit + 5)
    }

    @Test func choosesTheProtobufMessageType() {
        let schema = ProtobufSchema.load([("weather.proto", Self.weather)]).schema
        func reading(path: String? = nil, isRequest: Bool = false, chosen: String? = nil) -> ProtobufReading {
            ProtobufReading(schema: schema, path: path, isRequest: isRequest, chosenType: chosen)
        }
        let get = "/weather.v1.Forecasts/Get"
        // The type chosen for bodies like this one comes first, if the schema has it.
        let chosen = reading(path: get, chosen: "weather.v1.GetRequest")
        #expect(chosen.messageType(contentType: nil) == "weather.v1.GetRequest")
        // Then the type the gRPC method takes or returns.
        #expect(reading(path: get, chosen: "nope.Gone").messageType(contentType: nil) == "weather.v1.Forecast")
        #expect(reading(path: get, isRequest: true).messageType(contentType: nil) == "weather.v1.GetRequest")
        // Then the one the Content-Type names.
        let named = "application/x-protobuf; messageType=weather.v1.Forecast"
        #expect(reading().messageType(contentType: named) == "weather.v1.Forecast")
        #expect(reading().messageType(contentType: "application/x-protobuf; messageType=nope.Gone") == nil)
        #expect(reading().messageType(contentType: "application/x-protobuf") == nil)
    }

    @Test func readsProtobufWithAndWithoutItsType() throws {
        let schema = ProtobufSchema.load([("weather.proto", Self.weather)]).schema
        let typed = present(
            Data(Self.amsterdam), "application/x-protobuf",
            protobuf: ProtobufReading(schema: schema, path: nil, isRequest: false, chosenType: "weather.v1.Forecast"))
        #expect(typed.readsAsProtobuf)
        #expect(typed.protobufType == "weather.v1.Forecast")
        #expect(typed.modes == [.formatted, .tree, .hex])
        #expect(try #require(typed.formatted).text.contains("city"))

        // Without a schema, fields show by number.
        let untyped = present(Data(Self.amsterdam), "application/x-protobuf")
        #expect(untyped.readsAsProtobuf)
        #expect(untyped.protobufType == nil)
        #expect(try #require(untyped.formatted).text.contains("Amsterdam"))
    }

    @Test func readsGRPCMessagesAndTheirStatus() {
        let status = Array("grpc-status: 5\r\ngrpc-message: No%20such%20city\r\n".utf8)
        let web = present(
            Data(Self.frame(Self.amsterdam) + Self.frame(status, flags: 0x80)), "application/grpc-web+proto")
        #expect(web.messageCount == 1)
        #expect(web.grpcStatus?.code == 5)
        #expect(web.readsAsProtobuf)
        #expect(web.modes == [.formatted, .tree, .hex])

        // A message that hasn't all arrived yet.
        let partial = present(Data(Self.frame(Self.amsterdam) + [0, 0, 0]), "application/grpc")
        #expect(partial.messageCount == 1)
        #expect(partial.details.contains { $0.contains("partway through a message") })

        // gRPC can carry JSON instead.
        let json = present(Data(Self.frame(Array(#"{"city":"Oslo"}"#.utf8))), "application/grpc+json")
        #expect(json.readsAsProtobuf == false)
        #expect(json.modes == [.formatted, .tree, .hex])
        #expect(json.formatted?.text.contains("Oslo") == true)
    }
}
