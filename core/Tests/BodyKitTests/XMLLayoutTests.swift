import Foundation
import Testing

@testable import BodyKit

#if os(Windows)
    import WinSDK
#endif

/// Reqly's own XML layout, which every system uses. It must lay bodies out as Foundation's
/// XMLDocument does on the Mac, which `XMLLayoutOracleTests` checks there.
@Suite struct XMLLayoutTests {
    @Test func laysOutOneElementPerLine() {
        let request = """
            <?xml version="1.0" encoding="utf-8"?>
            <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><soap:Body><GetWeather \
            xmlns="http://www.example.com/weather"><City>Amsterdam</City><Days xsi:nil="true"/>\
            </GetWeather></soap:Body></soap:Envelope>
            """
        #expect(
            XMLLayout.formatted(request) == """
                <?xml version="1.0" encoding="utf-8" standalone="yes"?>
                <soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" \
                xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
                    <soap:Body>
                        <GetWeather xmlns="http://www.example.com/weather">
                            <City>Amsterdam</City>
                            <Days xsi:nil="true"></Days>
                        </GetWeather>
                    </soap:Body>
                </soap:Envelope>
                """)
        // Whitespace between elements goes, and the rest is indented again.
        #expect(
            XMLLayout.formatted("<a>\r\n  <b>1</b>\r\n  <c/>\r\n  <d> two words </d>\r\n</a>") == """
                <?xml version="1.0" encoding="UTF-8"?>
                <a>
                    <b>1</b>
                    <c></c>
                    <d> two words </d>
                </a>
                """)
    }

    @Test func keepsTextBesideTheTagsAroundIt() {
        #expect(
            XMLLayout.formatted("<p>Hello <b>world</b>!</p>") == """
                <?xml version="1.0" encoding="UTF-8"?>
                <p>Hello <b>world</b>
                    !</p>
                """)
        #expect(
            XMLLayout.formatted("<r><p>a<b>x</b>c<i>y</i>d</p></r>") == """
                <?xml version="1.0" encoding="UTF-8"?>
                <r>
                    <p>a<b>x</b>
                        c<i>y</i>
                        d</p>
                </r>
                """)
        #expect(
            XMLLayout.formatted("<!-- before --><?xml-stylesheet href=\"f.xsl\"?><a><!-- note --><?pi data?></a>")
                == """
                <?xml version="1.0" encoding="UTF-8"?>
                <!-- before -->
                <?xml-stylesheet href="f.xsl"?>
                <a>
                    <!-- note -->
                    <?pi data?>
                </a>
                """)
    }

    @Test func writesTheDeclarationAsXMLDocumentDoes() {
        #expect(XMLLayout.formatted("<a/>") == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a></a>")
        #expect(
            XMLLayout.formatted("<?xml version='1.0'?><a/>")
                == "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<a></a>")
        #expect(
            XMLLayout.formatted("<?xml version=\"1.0\" encoding=\"iso-8859-1\" standalone=\"no\"?><a/>")
                == "<?xml version=\"1.0\" encoding=\"iso-8859-1\"?>\n<a></a>")
    }

    @Test func escapesTextAndValues() {
        #expect(
            XMLLayout.formatted(#"<a x='a"b' y="&lt;&gt;&amp;&apos;">a &lt; b &gt; c &amp; "d"</a>"#)
                == #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
                + #"<a x="a&quot;b" y="&lt;&gt;&amp;'">a &lt; b &gt; c &amp; "d"</a>"#)
        // A value's whitespace becomes spaces, but what references stand for stays.
        #expect(
            XMLLayout.formatted("<a x=\"tab\there\nline\" y=\"&#10;&#9;\"/>")
                == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a x=\"tab here line\" y=\"\n\t\"></a>")
        #expect(
            XMLLayout.formatted("<a>one <![CDATA[<two> & three]]> four</a>")
                == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a>one &lt;two&gt; &amp; three four</a>")
    }

    @Test func readsTheDoctype() {
        let note = """
            <!DOCTYPE note [
            <!ENTITY writer "Donald Duck">
            <!ATTLIST note id ID #REQUIRED>
            <!ELEMENT note (from|sign*|to?)*>
            ]>
            <note id="n1"><from>&writer;</from><sign>&#169; &writer;</sign></note>
            """
        #expect(
            XMLLayout.formatted(note) == """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE note [
                    <!ENTITY writer "Donald Duck">
                    <!ATTLIST note id ID #REQUIRED>
                    <!ELEMENT note (from | sign | to)*>
                ]>

                <note id="n1">
                    <from>Donald Duck</from>
                    <sign>© Donald Duck</sign>
                </note>
                """)
        // An external subset could declare `&eacute;`, so it's allowed, and left out.
        let plist = """
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\
            <plist version="1.0"><string>caf&eacute; &amp; more</string></plist>
            """
        #expect(
            XMLLayout.formatted(plist) == """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">

                <plist version="1.0">
                    <string>caf &amp; more</string>
                </plist>
                """)
        #expect(XMLLayout.formatted("<plist><string>caf&eacute;</string></plist>") == nil)
    }

    @Test func writesHTMLAsXMLDocumentDoes() {
        let html = """
            <html><head><title>T</title></head><body><p>a<br/>b</p><input checked="checked"/>\
            <script>if (a &lt; b) {}</script></body></html>
            """
        #expect(
            XMLLayout.formatted(html) == """

                <html>
                    <head>
                        <title>T</title>
                    </head>
                    <body>
                        <p>a<br>
                            b</p>
                        <input checked>
                        <script>if (a < b) {}</script>
                    </body>
                </html>
                """)
        let xhtml = """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><meta http-equiv="Content-Type" \
            content="text/html; charset=ISO-8859-1"/></head><body><BR/><P>x</P></body></html>
            """
        #expect(
            XMLLayout.formatted(xhtml) == """
                <?xml version="1.0" encoding="ISO-8859-1"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                    <head>
                        <meta http-equiv="Content-Type" content="text/html; charset=ISO-8859-1" />
                    </head>
                    <body>
                        <br />
                        <p>x</p>
                    </body>
                </html>
                """)
    }

    @Test(arguments: XMLBodies.services)
    func readsWhatServicesSend(_ body: String) {
        #expect(XMLLayout.formatted(body) != nil)
    }

    @Test(arguments: [
        "", "   ", "plain text", "{\"json\": true}", "<a>", "<a></b>", "<a><b></a></b>", "<a/><b/>", "<a/>text",
        "text<a/>", " <?xml version=\"1.0\"?><a/>", "<a x=1/>", "<a x=\"1\" x=\"2\"/>", "<a x=\"<\"/>",
        "<a x=\"1\"y=\"2\"/>", "<a>&</a>", "<a>&nbsp;</a>", "<a>&#0;</a>", "<a>\u{1}</a>", "<a>]]></a>",
        "<a><!-- a -- b --></a>", "<a><![CDATA[open</a>", "<a/><!DOCTYPE a>", "<?xml version=\"2.0\"?><a/>",
        "<?xml version=\"1.0\" encoding=\"UTF-16\"?><a/>", "<a><?xml version=\"1.0\"?></a>", "<1a/>",
        "<p:a/>", "<a p:x=\"1\"/>", "<a xmlns:p=\"\"/>", "<a xmlns:p=\"not a uri\"/>",
        "<a xml:id=\"x\"><b xml:id=\"x\"/></a>", "<!DOCTYPE a [<!ENTITY e \"&e;\">]><a>&e;</a>",
        "<!DOCTYPE a [<!ENTITY e \"<b>\">]><a>&e;</a>", "<!DOCTYPE a [<!ELEMENT a ANY><!ELEMENT a EMPTY>]><a/>",
        "<soap:Envelope><soap:Body/></soap:Envelope>",
    ])
    func refusesWhatIsNotWellFormed(_ text: String) {
        #expect(XMLLayout.formatted(text) == nil)
        #expect(MarkupSyntax.formattedXML(text) == text)
    }

    @Test func readsDeepNestingWithoutRecursion() async {
        let depth = 100_000
        let text = String(repeating: "<a>", count: depth) + "x" + String(repeating: "</a>", count: depth)
        // The apps format bodies in detached tasks, whose threads have small stacks. XMLDocument
        // runs out of stack there at about 2,400 levels.
        let layout = await Task.detached { MarkupSyntax.formattedXML(text) }.value
        // A line per element and one for the declaration, and indents stop growing.
        let lines = layout.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2 * depth)
        let deepest = String(repeating: " ", count: 4 * XMLLayout.deepestIndent)
        #expect(lines[depth] == deepest + "<a>x</a>")
        #expect(lines[depth - 1] == deepest + "<a>")
    }

    @Test func readsDeepDeclarationsWithoutRecursion() async {
        let depth = 100_000
        func model(nesting depth: Int) -> String {
            "<!DOCTYPE a [<!ELEMENT a " + String(repeating: "(", count: depth) + "b"
                + String(repeating: ")", count: depth) + ">]><a/>"
        }
        let chain =
            "<!DOCTYPE a [<!ENTITY e0 \"x\">" + (1..<depth).map { "<!ENTITY e\($0) \"&e\($0 - 1);\">" }.joined()
            + "]><a>&e\(depth - 1);</a>"
        let layouts = await Task.detached {
            (
                XMLLayout.formatted(model(nesting: 128)), XMLLayout.formatted(model(nesting: depth)),
                XMLLayout.formatted(chain)
            )
        }.value
        #expect(
            layouts.0
                == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE a [\n    <!ELEMENT a (b)>\n]>\n\n<a></a>")
        // XMLParser refuses groups nested deeper than 128.
        #expect(layouts.1 == nil)
        #expect(layouts.2?.hasSuffix("    <!ENTITY e\(depth - 1) \"&e\(depth - 2);\">\n]>\n\n<a>x</a>") == true)
    }

    @Test func readsBigBodies() throws {
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss version=\"2.0\"><channel>"
        let item = """
            <!-- An item --><item id="i" rank="7"><title>Item &amp; more</title>\
            <link>https://example.com/i?a=1&amp;b=2</link>\
            <author><![CDATA[Writer <w@example.com>]]></author><description>Text with café, &lt;b&gt;markup\
            &lt;/b&gt; and &#x263A;.</description><empty/></item>
            """
        let count = 5 << 20 / item.utf8.count
        text.reserveCapacity(count * item.utf8.count + 100)
        for _ in 0..<count {
            text += item
        }
        text += "</channel></rss>"
        let layout = try #require(XMLLayout.formatted(text))
        let laidOut = """

                    <!-- An item -->
                    <item id="i" rank="7">
                        <title>Item &amp; more</title>
                        <link>https://example.com/i?a=1&amp;b=2</link>
                        <author>Writer &lt;w@example.com&gt;</author>
                        <description>Text with café, &lt;b&gt;markup&lt;/b&gt; and ☺.</description>
                        <empty></empty>
                    </item>
            """
        let expected =
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<rss version=\"2.0\">\n    <channel>"
            + String(repeating: laidOut, count: count) + "\n    </channel>\n</rss>"
        #expect(layout == expected)
    }

    /// libxml2 adds a namespace the DOCTYPE gives an element unless the prefix is bound to the
    /// value of the element's first default, whichever that is, and an empty default namespace
    /// each time.
    @Test func addsNamespaceDefaultsAsLibxml2Does() {
        #expect(
            XMLLayout.formatted(
                "<!DOCTYPE r [<!ATTLIST e a CDATA \"zzz\" xmlns:q CDATA #FIXED \"urn:q\">]><r xmlns:q=\"urn:q\"><e/></r>"
            )?
            .hasSuffix("<r xmlns:q=\"urn:q\">\n    <e xmlns:q=\"urn:q\"></e>\n</r>") == true)
        #expect(
            XMLLayout.formatted("<!DOCTYPE r [<!ATTLIST e xmlns CDATA #FIXED \"\">]><r><e><e/></e></r>")?
                .hasSuffix("<r>\n    <e xmlns=\"\">\n        <e xmlns=\"\"></e>\n    </e>\n</r>") == true)
    }

    /// Defaults that write nothing take a little reading for each element, but no room in the
    /// layout.
    @Test func readsDefaultsForEachElement() throws {
        let declaration = "<!DOCTYPE r [<!ATTLIST e" + (0..<10).map { " p:a\($0) CDATA \"1\"" }.joined() + ">]>"
        let layout = try #require(
            XMLLayout.formatted(
                declaration + "<r xmlns:p=\"urn:p\">" + String(repeating: "<e/>", count: 60_000) + "</r>"))
        #expect(layout.components(separatedBy: "\n    <e></e>").count == 60_001)
    }

    @Test func refusesEntitiesThatExpandTooFar() {
        var declarations = "<!ENTITY l0 \"lollollollol\">"
        for level in 1...9 {
            declarations += "<!ENTITY l\(level) \"" + String(repeating: "&l\(level - 1);", count: 10) + "\">"
        }
        #expect(XMLLayout.formatted("<!DOCTYPE a [\(declarations)]><a>&l9;</a>") == nil)
        #expect(XMLLayout.formatted("<!DOCTYPE a [\(declarations)]><a>&l3;</a>") != nil)
    }
}

/// Bodies the apps must take care with: what they must never read, and what crashed
/// XMLDocument or made it write a huge layout. These run everywhere, through what the apps call.
@Suite struct XMLLayoutSafetyTests {
    @Test func neverReadsExternalEntities() throws {
        let secret = "secret-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory
        let file = folder.appendingPathComponent("reqly-\(UUID().uuidString).txt")
        let dtd = folder.appendingPathComponent("reqly-\(UUID().uuidString).dtd")
        try Data(secret.utf8).write(to: file)
        try Data("<!ENTITY e \"\(secret)\">".utf8).write(to: dtd)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: dtd)
        }
        let bodies = [
            "<!DOCTYPE a [<!ENTITY x SYSTEM \"\(file.absoluteString)\">]><a>&x;</a>",
            "<!DOCTYPE a [<!ENTITY x SYSTEM \"\(file.path)\">]><a>&x;</a>",
            "<!DOCTYPE a [<!ENTITY x SYSTEM \"\(file.absoluteString)\">]><a b=\"&x;\"/>",
            // A DTD that would declare `&e;`, as the external subset or a parameter entity.
            "<!DOCTYPE a SYSTEM \"\(dtd.absoluteString)\"><a>&e;</a>",
            "<!DOCTYPE a SYSTEM \"x\" [<!ENTITY % p SYSTEM \"\(dtd.absoluteString)\"> %p;]><a>&e;</a>",
        ]
        for body in bodies {
            #expect(!MarkupSyntax.formattedXML(body).contains(secret))
        }
        // The entity is left out, and the rest laid out.
        #expect(
            MarkupSyntax.formattedXML(bodies[0]) == """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE a [
                    <!ENTITY x SYSTEM "\(file.absoluteString)">
                ]>

                <a></a>
                """)
    }

    /// Namespace errors that made XMLDocument crash the app, though XMLParser let them through.
    @Test(arguments: [
        "<ns0:a x0=\"\" xmlns:ns1=\"u\" x=\"\"><ns1:b xmlns=\"u\"></ns1:b></ns0:a>",
        "<!DOCTYPE a [<!ENTITY e \"\">]><a :=\"\" xmlns=\"u\"></a>",
        "<doc><a></a><b></b><f></f><g></g><h></h><j :=\"\"></j><k xml:space=\"\"></k></doc>",
        "<!DOCTYPE a [<!ENTITY e \"<b/>\">]><a l:space=\"preV\" xmlns=\"urn:d\">&e;</a>",
        "<!DOCTYPE a [<!ENTITY e \"<b/>\">]><a xml:=\"preV\" xmlns=\"urn:d\">&e;</a>",
        "<x-y c=\"\"><q:e><z.1><z.1 xmlns=\"l\"></z.1></z.1><z.1><a c=\"\"></a></z.1></q:e></x-y>",
        "<?l?><soap:Envelope i=\"\" p=\"\"><soap:Header><AuthHeader s=\"\"><Token></Token></AuthHeader>"
            + "</soap:Header><soap:Body><GetQuoteResponse xmlns=\"/\"><GetQuoteResult x=\"\"><![CDATA[]]>"
            + "</GetQuoteResult></GetQuoteResponse></soap:Body></soap:Envelope>",
        "<?xml version=\"1.0\"?><?xml-stylesheet href=\"a.xsl\"?><soap:Envelope><soap:Body><r xmlns=\"urn:x\">"
            + "<v a=\"1\">x</v></r></soap:Body></soap:Envelope>",
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ns0:a xmlns:nas0=\"urn:a\" xmlns:ns1=\"urn:b\" ns1:x=\"1\">"
            + "<ns1:b xmlns=\"?urn:c\"><c/></ns1:b><d xmlns=\"\"/></ns0:a>",
        "<!DOCTYPE a SYSTEM \"x.dtd\" [<!ENTITY % p \"<!ENTITY p: 'v'>\"> %p;]><a>&e; &u;</a>",
    ])
    func refusesWhatCrashedXMLDocument(_ body: String) {
        #expect(XMLLayout.formatted(body) == nil)
        #expect(MarkupSyntax.formattedXML(body) == body)
    }

    /// XMLDocument writes a namespace that the DOCTYPE gives an element by default on each element
    /// it's added to, so a small body can make a huge layout. The layout has a limit.
    @Test func refusesDefaultsThatAddTooMuch() {
        let long = "urn:" + String(repeating: "x", count: 100_000)
        let elements = String(repeating: "<e/>", count: 1_000)
        // Compared first, so a failure doesn't print the layout.
        let isRefused =
            XMLLayout.formatted("<!DOCTYPE r [<!ATTLIST e xmlns CDATA #FIXED \"\(long)\">]><r>\(elements)</r>") == nil
        #expect(isRefused)
        let layout = XMLLayout.formatted("<!DOCTYPE r [<!ATTLIST e xmlns CDATA #FIXED \"urn:e\">]><r>\(elements)</r>")
        #expect(layout?.components(separatedBy: "<e xmlns=\"urn:e\"></e>").count == 1_001)
    }

    /// XMLDocument writes an `<!ATTLIST>` as a line for each attribute, each with the element's
    /// name, so a small body with a long name can make a huge layout.
    @Test func refusesLayoutsThatGrowTooLong() {
        let name = String(repeating: "e", count: 50_000)
        let attributes = (0..<2_000).map { " a\($0) CDATA #IMPLIED" }.joined()
        let body = "<!DOCTYPE r [<!ATTLIST \(name)\(attributes)>]><r/>"
        // Compared first, so a failure doesn't print the layout.
        let isRefused = XMLLayout.formatted(body) == nil
        let isShownAsItCame = MarkupSyntax.formattedXML(body) == body
        #expect(isRefused)
        #expect(isShownAsItCame)
        // A few lines are fine.
        let lines = XMLLayout.formatted("<!DOCTYPE r [<!ATTLIST \(name) a CDATA #IMPLIED b CDATA #IMPLIED>]><r/>")
        #expect(lines?.components(separatedBy: name).count == 3)
    }

    /// XMLDocument stops the app on an XHTML 1.0 DOCTYPE whose `html` is in another namespace.
    @Test(arguments: ["urn:other", ""])
    func laysOutXHTMLDoctypesInAnotherNamespace(_ namespace: String) {
        let doctype = """
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" \
            "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
            """
        #expect(
            MarkupSyntax.formattedXML(doctype + "<html xmlns=\"\(namespace)\"><br/></html>") == """
                \(doctype)

                <html xmlns="\(namespace)">
                    <br>
                </html>
                """)
    }
}

/// Bodies whose layout took time that grew with the square of their size, in Reqly's reader or
/// in XMLDocument. Laying out a body eight times the size may take at most twice as long as laying
/// out the body eight times, at the best of three tries. It's timed in the test thread's processor
/// time, which a busy machine barely changes.
@Suite(.serialized) struct XMLLayoutSpeedTests {
    enum Body: CaseIterable, Sendable {
        /// Each comment or instruction made the reader copy the whole layout.
        case commentPerElement, instructionPerElement
        /// HTML ends the instructions before its root without `?`, which were taken out one by one.
        case instructionsBeforeHTML
        /// Once the DOCTYPE declared a type, each attribute was looked up by its element's whole name.
        case declaredTypesAndALongTag
        /// An `<!ATTLIST>` looked its element up by its whole name for each attribute, even one
        /// declared already, which writes nothing.
        case attributesDeclaredAgain
        /// Each default from the DOCTYPE was looked for among all the tag's attributes.
        case defaultsAndAttributes
        /// Each attribute with a prefix copied its namespace's URI.
        case prefixedAttributesInALongNamespace
        /// Each `<meta>` in XHTML made its parent's name lowercase, to see whether it's `head`.
        case metasInALongNamedElement
        /// Each undeclared reference in a default's value looked through the entities being read.
        case undeclaredReferencesInParameterEntities
        /// XMLDocument's HTML writer slows with the square of the void elements.
        case voidElementsInHTML

        /// How many times the smaller body repeats its part, which takes a few hundredths of a
        /// second in a debug build.
        var count: Int {
            switch self {
            case .defaultsAndAttributes: 1_500
            case .undeclaredReferencesInParameterEntities: 2_500
            case .declaredTypesAndALongTag, .prefixedAttributesInALongNamespace: 20_000
            default: 10_000
            }
        }

        func text(repeating count: Int) -> String {
            switch self {
            case .commentPerElement:
                "<r>" + String(repeating: "<a>x</a><!-- c -->", count: count) + "</r>"
            case .instructionPerElement:
                "<r>" + String(repeating: "<a>x</a><?pi d?>", count: count) + "</r>"
            case .instructionsBeforeHTML:
                String(repeating: "<?pi?>", count: count) + "<html/>"
            case .declaredTypesAndALongTag:
                "<!DOCTYPE r [<!ATTLIST r t NMTOKEN #IMPLIED>]><r><e" + String(repeating: "x", count: count)
                    + (0..<count / 8).map { " a\($0)=\"\"" }.joined() + "/></r>"
            case .attributesDeclaredAgain:
                "<!DOCTYPE r [<!ATTLIST " + String(repeating: "e", count: count)
                    + String(repeating: " a CDATA #IMPLIED", count: count) + ">]><r/>"
            case .defaultsAndAttributes:
                // Only defaults with a prefix, or namespaces, matter to the layout.
                "<!DOCTYPE r [<!ATTLIST r xmlns:p CDATA #FIXED \"urn:p\""
                    + (0..<count).map { " p:d\($0) CDATA \"\"" }.joined() + ">]><r"
                    + (0..<count).map { " a\($0)=\"\"" }.joined() + "/>"
            case .prefixedAttributesInALongNamespace:
                "<r xmlns:p=\"urn:" + String(repeating: "x", count: count) + "\"><e"
                    + (0..<count / 8).map { " p:a\($0)=\"\"" }.joined() + "/></r>"
            case .metasInALongNamedElement:
                "<html xmlns=\"http://www.w3.org/1999/xhtml\"><" + String(repeating: "h", count: count) + ">"
                    + String(repeating: "<meta/>", count: count) + "</" + String(repeating: "h", count: count)
                    + "></html>"
            case .undeclaredReferencesInParameterEntities:
                // Each entity's text refers to the next.
                "<!DOCTYPE a SYSTEM \"x\" [" + (0..<count).map { "<!ENTITY % e\($0) \"&#37;e\($0 + 1);\">" }.joined()
                    + "<!ENTITY % e\(count) \"<!ATTLIST a b CDATA '" + String(repeating: "&u;", count: count)
                    + "'>\"> %e0;]><a/>"
            case .voidElementsInHTML:
                "<html><body>" + String(repeating: "<br/>x", count: count) + "</body></html>"
            }
        }
    }

    @Test(arguments: Body.allCases)
    func takesTimeInProportionToTheBody(_ body: Body) {
        let small = body.text(repeating: body.count)
        let large = body.text(repeating: 8 * body.count)
        func layingOut(_ text: String, times: Int) -> Duration {
            var laidOut = 0
            let start = threadTime()
            for _ in 0..<times where XMLLayout.formatted(text) != nil {
                laidOut += 1
            }
            let time = threadTime() - start
            #expect(laidOut == times)
            return time
        }
        // Windows counts a thread's time in ticks of about 16 ms, so each side is laid out until
        // it has taken a tenth of a second, as many times for both.
        var rounds = 1
        var forSmall = layingOut(small, times: 8)
        while forSmall < .milliseconds(100) {
            rounds *= 2
            forSmall = layingOut(small, times: 8 * rounds)
        }
        var forLarge = layingOut(large, times: rounds)
        for _ in 0..<2 where forLarge / forSmall >= 2 {
            forSmall = min(forSmall, layingOut(small, times: 8 * rounds))
            forLarge = min(forLarge, layingOut(large, times: rounds))
        }
        #expect(
            forLarge / forSmall < 2,
            "\(forSmall) for the body \(8 * rounds) times, \(forLarge) for eight times the body \(rounds) times")
    }

    /// The processor time the current thread has had.
    func threadTime() -> Duration {
        #if os(Windows)
            var created = FILETIME()
            var exited = FILETIME()
            var kernel = FILETIME()
            var user = FILETIME()
            GetThreadTimes(GetCurrentThread(), &created, &exited, &kernel, &user)
            // It counts in steps of 100 nanoseconds.
            let steps = [kernel, user].map { Int64($0.dwHighDateTime) << 32 | Int64($0.dwLowDateTime) }
            return .nanoseconds(100 * steps.reduce(0, +))
        #else
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return .seconds(Int64(time.tv_sec)) + .nanoseconds(Int64(time.tv_nsec))
        #endif
    }
}

#if os(macOS)
    /// Foundation's XMLDocument is the reference: Reqly's own layout must agree with it on what's
    /// well-formed, and lay bodies out as it does.
    @Suite struct XMLLayoutOracleTests {
        @Test(arguments: XMLBodies.services + XMLBodies.cases + XMLBodies.deepContentModels)
        func agreesWithFoundation(_ body: String) {
            let layout = XMLLayout.formatted(body)
            let foundation = foundationLayout(body)
            #expect((layout == nil) == (foundation == nil))
            #expect(layout == foundation)
        }

        /// Where the two differ on purpose, as XMLLayout lists, they still agree on what's
        /// well-formed.
        @Test(arguments: [
            // Foundation reads the text again as the declaration's encoding, and garbles it.
            (
                "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>café</a>",
                "<?xml version=\"1.0\" encoding=\"ISO-8859-1\" standalone=\"yes\"?>\n<a>café</a>"
            ),
            // Foundation drops a U+FEFF that starts a text, a value or a comment.
            (
                "<a b=\"\u{FEFF}x\">\u{FEFF}y<!--\u{FEFF}--></a>",
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a b=\"\u{FEFF}x\">\u{FEFF}y<!--\u{FEFF}-->\n</a>"
            ),
            ("<a>&#xFEFF;x</a>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a>\u{FEFF}x</a>"),
            // Foundation keeps `\r` in CDATA sections and public IDs.
            ("<a><![CDATA[x\r\ny\rz]]></a>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a>x\ny\nz</a>"),
            (
                "<!DOCTYPE a PUBLIC \"x\r\ny\" \"s\"><a/>",
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE a PUBLIC \"x\ny\" \"s\">\n\n<a></a>"
            ),
            // Foundation makes a tab that a reference in an entity stands for a space in a value, and
            // `\r` a `\n` in text.
            (
                "<!DOCTYPE a [<!ENTITY e \"&#38;#9;\">]><a b=\"&e;\"/>",
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE a [\n    <!ENTITY e \"&#9;\">\n]>\n\n<a b=\"\t\"></a>"
            ),
            (
                "<!DOCTYPE a [<!ENTITY e \"a&#13;d\">]><a>&e;</a>",
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE a [\n    <!ENTITY e \"a\rd\">\n]>\n\n<a>a\rd</a>"
            ),
            // Foundation reads an entity's elements in no namespace, and writes `xmlns=""` on them.
            (
                "<!DOCTYPE a [<!ENTITY e \"<b/>\">]><a xmlns=\"urn:x\">&e;</a>",
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE a [\n    <!ENTITY e \"<b/>\">\n]>\n\n"
                    + "<a xmlns=\"urn:x\">\n    <b></b>\n</a>"
            ),
            // Foundation indents every level.
            nestedPastTheDeepestIndent,
        ])
        func differsWhereItMeansTo(_ body: String, layout: String) {
            #expect(foundationLayout(body) != nil)
            #expect(foundationLayout(body) != layout)
            #expect(XMLLayout.formatted(body) == layout)
        }

        /// Elements nested 40 deep, and how Reqly lays them out, with lines that stop moving right
        /// after 32 levels.
        static let nestedPastTheDeepestIndent: (String, String) = {
            let depth = 40
            func indent(_ level: Int) -> String {
                String(repeating: " ", count: 4 * min(level, XMLLayout.deepestIndent))
            }
            let lines =
                ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>"] + (0..<depth - 1).map { indent($0) + "<a>" }
                + [indent(depth - 1) + "<a>x</a>"] + (0..<depth - 1).reversed().map { indent($0) + "</a>" }
            let body = String(repeating: "<a>", count: depth) + "x" + String(repeating: "</a>", count: depth)
            return (body, lines.joined(separator: "\n"))
        }()

        /// libxml2 refuses a name over 50,000 bytes, which Reqly lays out.
        @Test func readsLongerNamesThanLibxml2() {
            let name = String(repeating: "n", count: 50_001)
            #expect(foundationLayout("<\(name)/>") == nil)
            #expect(
                XMLLayout.formatted("<\(name)/>") == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<\(name)></\(name)>")
        }

        /// libxml2 checks an `xml:id` with the fourth edition's letters, which Reqly checks as it
        /// does names, with the fifth's.
        @Test func readsFifthEditionIDs() {
            let body = "<a xml:id=\"\u{2C00}\"/>"
            #expect(foundationLayout(body) == nil)
            #expect(
                XMLLayout.formatted(body) == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<a xml:id=\"\u{2C00}\"></a>")
        }

        /// libxml2 refuses entities nested 18 deep in text, which Reqly reads.
        @Test func readsDeeperEntitiesThanLibxml2() {
            let chain =
                "<!DOCTYPE a [<!ENTITY e0 \"x\">" + (1..<18).map { "<!ENTITY e\($0) \"&e\($0 - 1);\">" }.joined()
                + "]><a>&e17;</a>"
            #expect(foundationLayout(chain) == nil)
            #expect(XMLLayout.formatted(chain)?.hasSuffix("\n\n<a>x</a>") == true)
        }
    }

    /// XML laid out by Foundation's XMLDocument, as Reqly for Mac 1.0 lays it out, or nil when it
    /// isn't well-formed. External entities aren't loaded, since Reqly's reader never loads them.
    private func foundationLayout(_ text: String) -> String? {
        let parser = XMLParser(data: Data(text.utf8))
        let elements = ElementBalance()
        parser.delegate = elements
        // XMLParser checks it first, as in Reqly for Mac 1.0: no error, and every element it opened
        // closed.
        guard parser.parse(), parser.parserError == nil, elements.isBalanced,
            let document = try? XMLDocument(
                xmlString: text, options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever])
        else {
            return nil
        }
        return document.xmlString(options: [.nodePrettyPrint])
    }

    /// Counts the elements an XML parser opens and closes.
    private final class ElementBalance: NSObject, XMLParserDelegate {
        private var depth = 0
        private var sawElement = false

        /// Whether there was an element, and every element was closed.
        var isBalanced: Bool { sawElement && depth == 0 }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            depth += 1
            sawElement = true
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            depth -= 1
        }
    }
#endif

/// Bodies the layout is checked on.
enum XMLBodies {
    /// Bodies as services send them.
    static let services: [String] = [
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope" xmlns:rpc="http://www.w3.org/2003/05/soap-rpc">
          <env:Header><wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" env:mustUnderstand="true"><wsse:UsernameToken><wsse:Username>reqly</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordText">s3cr&amp;t</wsse:Password></wsse:UsernameToken></wsse:Security></env:Header>
          <env:Body>
            <env:Fault>
              <env:Code><env:Value>env:Sender</env:Value><env:Subcode><env:Value>rpc:BadArguments</env:Value></env:Subcode></env:Code>
              <env:Reason><env:Text xml:lang="en-US">Processing error</env:Text><env:Text xml:lang="cs">Chyba zpracování</env:Text></env:Reason>
              <env:Detail><e:myFaultDetails xmlns:e="http://travelcompany.example.org/faults"><e:message>Name does not match</e:message><e:errorcode>999</e:errorcode></e:myFaultDetails></env:Detail>
            </env:Fault>
          </env:Body>
        </env:Envelope>
        """,
        """
        <?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:content="http://purl.org/rss/1.0/modules/content/">\
        <channel><title>Reqly &amp; friends</title><link>https://reqly.net/</link><atom:link \
        href="https://reqly.net/feed.xml" rel="self" type="application/rss+xml"/><item><title>Reqly 1.0</title>\
        <dc:creator><![CDATA[Parsa]]></dc:creator><guid isPermaLink="false">reqly-1.0</guid><description><![CDATA[<p>Reqly \
        1.0 is <b>out</b> &mdash; download it now.</p>]]></description><content:encoded>&lt;p&gt;Hello&lt;/p&gt;\
        </content:encoded><enclosure url="https://reqly.net/a.mp3" length="12345" type="audio/mpeg"/></item></channel></rss>
        """,
        """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"><title type="text">Example Feed</title><subtitle type="html">A \
        &lt;em&gt;lot&lt;/em&gt; of effort</subtitle><updated>2026-10-20T18:30:02Z</updated><link rel="alternate" \
        type="text/html" hreflang="en" href="http://example.org/"/><entry><title>Atom-Powered Robots Run Amok</title>\
        <content type="xhtml" xml:lang="en" xml:base="http://diveintomark.org/"><div xmlns="http://www.w3.org/1999/xhtml">\
        <p><i>[Update: The Atom draft is finished.]</i></p><p>Some <b>bold</b> text and a <a href="/x?a=1&amp;b=2">link\
        </a>.</p></div></content></entry></feed>
        """,
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>CFBundleIdentifier</key>
        \t<string>net.reqly.Reqly</string>
        \t<key>Items</key>
        \t<array>
        \t\t<integer>1</integer>
        \t\t<real>2.5</real>
        \t\t<true/>
        \t\t<data>
        \t\tSGVsbG8=
        \t\t</data>
        \t</array>
        \t<key>Empty</key>
        \t<dict/>
        </dict>
        </plist>
        """,
        """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <!-- Generator: Sketch -->
        <svg width="24px" height="24px" viewBox="0 0 24 24" version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
            <title>icon</title>
            <defs><style type="text/css"><![CDATA[ .a { fill: #0a7; } ]]></style><linearGradient id="g"><stop offset="0" stop-color="#fff"/></linearGradient></defs>
            <g id="Page-1" stroke="none" fill-rule="evenodd"><path d="M12,2 L22,22 L2,22 Z" class="a"/><use xlink:href="#g"/><text x="1" y="2">A &lt; B</text></g>
        </svg>
        """,
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en"><head><meta http-equiv="Content-Type" \
        content="text/html; charset=utf-8"/><title>Reqly &#8212; Network inspector</title><script type="text/javascript">
        //<![CDATA[
        if (a < b && c) { go(); }
        //]]></script></head><body><h1>Hello&#160;world</h1><p>Some <em>emphasis</em>, a<br/>break and &copy; 2026.</p>\
        <ul><li>One</li><li>Two <a href="#">links</a></li></ul></body></html>
        """,
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">\
        <url><loc>https://reqly.net/</loc><lastmod>2026-10-20</lastmod><priority>1.0</priority><image:image><image:loc>\
        https://reqly.net/icon.png</image:loc></image:image></url><url><loc>https://reqly.net/docs?lang=en&amp;v=2</loc></url></urlset>
        """,
        """
        <?xml version="1.0" encoding="utf-8"?>
        <manifest xmlns:android="http://schemas.android.com/apk/res/android"
            xmlns:tools="http://schemas.android.com/tools"
            package="net.reqly.companion">

            <uses-permission android:name="android.permission.INTERNET" />
            <!-- Reqly's companion app -->
            <application
                android:allowBackup="true"
                android:label="@string/app_name"
                tools:targetApi="34">
                <activity android:name=".MainActivity" android:exported="true">
                    <intent-filter>
                        <action android:name="android.intent.action.MAIN" />
                    </intent-filter>
                </activity>
            </application>
        </manifest>
        """,
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
          <modelVersion>4.0.0</modelVersion>
          <groupId>net.reqly</groupId>
          <dependencies>
            <!-- Tests -->
            <dependency>
              <groupId>junit</groupId>
              <scope>test</scope>
            </dependency>
          </dependencies>
        </project>

        """.replacingOccurrences(of: "\n", with: "\r\n"),
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>bucket</Name><Prefix/><KeyCount>2\
        </KeyCount><IsTruncated>false</IsTruncated><Contents><Key>my image.jpg</Key><ETag>&quot;fba9dede5f27731c&quot;\
        </ETag><Size>434234</Size></Contents><Contents><Key>a&amp;b.txt</Key><Size>0</Size></Contents></ListBucketResult>
        """,
        """
        <?xml version="1.0" encoding="utf-8" ?>
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>/container/</D:href><D:propstat><D:prop><D:displayname>\
        Example collection</D:displayname><D:resourcetype><D:collection/></D:resourcetype><D:supportedlock><D:lockentry>\
        <D:lockscope><D:exclusive/></D:lockscope></D:lockentry></D:supportedlock></D:prop><D:status>HTTP/1.1 200 OK\
        </D:status></D:propstat></D:response></D:multistatus>
        """,
        """
        <?xml version="1.0"?>
        <methodCall><methodName>examples.getStateName</methodName><params><param><value><i4>41</i4></value></param>\
        <param><value><string>South &lt;Dakota&gt;</string></value></param></params></methodCall>
        """,
        """
        <?xml version="1.0"?>
        <?xml-stylesheet type="text/xsl" href="style.xsl"?>
        <catalog>
           <book id="bk101">
              <author>Gambardella, Matthew</author>
              <description>An in-depth look at creating applications
              with XML.</description>
           </book>
        </catalog>
        """,
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
        xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" mc:Ignorable="w14"><w:body><w:p \
        w:rsidR="00F1"><w:r><w:t xml:space="preserve">Hello </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>world</w:t>\
        </w:r></w:p><w:sectPr/></w:body></w:document>
        """,
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><Placemark><name>Simple placemark</name><Point>\
        <coordinates>-122.08,37.42,0</coordinates></Point></Placemark></Document></kml>
        """,
        """
        <html><head><title>A page sent as XML</title><style>p > b { color: red }</style></head><body \
        onload="go('x')"><p class="a">Some <b>bold</b> &amp; <i>more</i><br/>text.</p><img src="a b.png" alt=""/>\
        <form action="/a?b=1&amp;c=2"><input type="checkbox" checked="checked" disabled=""/></form></body></html>
        """,
    ]

    /// Small bodies, each of one thing XML allows or refuses.
    static let cases: [String] = [
        // The declaration.
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><a/>", "<?xml version='1.0' encoding='utf-8'?><a/>",
        "<?xml version=\"1.1\"?><a/>", "<?xml version=\"2.0\"?><a/>",
        "<?xml version=\"1.0\" standalone=\"maybe\"?><a/>",
        "<?xml version=\"1.0\" foo=\"x\"?><a/>", "<?xml encoding=\"UTF-8\" version=\"1.0\"?><a/>",
        "<?xml version=\"1.0\"encoding=\"UTF-8\"?><a/>", "<?xml version=\"1.0\" encoding=\"UTF-16\"?><a/>",
        "<?xml?><a/>", " <?xml version=\"1.0\"?><a/>", "\u{FEFF}<a/>", "<a/><?xml version=\"1.0\"?>",
        // Elements and attributes.
        "", "  ", "<a>", "<a></b>", "<a></a >", "< a/>", "<a/ >", "<a />", "<1a/>", "<a.b-c_d/>", "<é·/>",
        "<a/><b/>", "<a/>text", "text<a/>", "<a/>  \n", "<a b=\"1\"c=\"2\"/>", "<a b=1/>", "<a b/>", "<a b=\"<\"/>",
        "<a b='\"' c=\"'\" d=\">\"/>", "<a b=\"1\" b=\"2\"/>", "<a b=\"x\ty\r\nz&#13;\"/>",
        "<a>\n  <b>1</b>\n  <c/>\n</a>", "<a> <b/> text <c/> </a>", "<a>t1<!--c-->t2</a>",
        "<r><p>a<b><c>deep</c></b>z</p></r>", "<p><b>world</b> tail</p>", "<a><b> 1 </b></a>",
        // Text, references and CDATA.
        "<a>&lt;&gt;&amp;&quot;&apos;</a>", "<a>&#65;&#x263A;&#xA0;&#x1F600;</a>", "<a>&#X41;</a>", "<a>&#65</a>",
        "<a>&#xD800;</a>", "<a>&#0;</a>", "<a>& b</a>", "<a>x]]>y</a>", "<a>x]]y</a>", "<a>\u{7F}\u{85}</a>",
        "<a>\u{1}</a>", "<a>\u{FFFE}</a>", "<a> <![CDATA[x<y]]> </a>", "<a><b/><![CDATA[x]]><c/></a>",
        "<a><![cdata[x]]></a>", "<a></a><![CDATA[x]]>", "<a>\r\ny\rz</a>",
        // Comments and processing instructions.
        "<a><!----></a>", "<a><!-- a -- b --></a>", "<a><!-- a ---></a>", "<a><!--->--></a>",
        "<!-- only a comment -->", "<a><?pi   x  y ?></a>", "<a><?pi ?></a>", "<a><?pi?x?></a>", "<a><? pi?></a>",
        "<a><?XmL x?></a>", "<a><?xml-foo x?></a>", "<a><?p:i x?></a>",
        // Namespaces.
        "<p:a xmlns:p=\"urn:p\"><p:b/></p:a>", "<a:b/>", "<a xmlns:p=\"urn:p\" p:x=\"1\" x=\"2\"/>",
        "<a x=\"1\" xmlns=\"urn:a\" xmlns:p=\"urn:p\" p:y=\"2\"/>",
        "<a xmlns:p=\"urn:x\" xmlns:q=\"urn:x\" p:x=\"1\" q:x=\"2\"/>",
        "<a xmlns=\"a b\"/>", "<a xmlns:p=\"caf\u{E9}\"/>", "<a xmlns:p=\"http://ex.com/?q=1&amp;r=2#f[1]\"/>",
        "<a xmlns:p=\"%41\"/>", "<a xmlns:p=\"%zz\"/>", "<a xmlns:p=\"http://[::1]:8080/\"/>",
        "<a xmlns:p=\"http://h:/\"/>",
        "<a xmlns:xml=\"http://www.w3.org/XML/1998/namespace\" xml:lang=\"en\"/>", "<a xmlns:xml=\"urn:wrong\"/>",
        "<a xmlns:xmlns=\"urn:x\"/>", "<xmlns:a/>", "<a:b:c/>", "<a :x=\"1\"/>",
        "<a xmlns=\"\"><b xmlns=\"urn:b\"/></a>",
        "<a xml:id=\" x \"/>", "<a xml:id=\"\"/>", "<a xml:id=\"a:b\"/>",
        // The DOCTYPE.
        "<!DOCTYPE a><a/>", "<!DOCTYPE a SYSTEM \"a.dtd\"><a>&nbsp;x</a>", "<!DOCTYPE a><a>&nbsp;</a>",
        "<!DOCTYPE a PUBLIC \"x\"><a/>", "<!DOCTYPE a PUBLIC \"a{b\" \"c\"><a/>", "<!DOCTYPEa><a/>", "<!DOCTYPE b><a/>",
        "<!DOCTYPE a><!DOCTYPE a><a/>", "<!-- c --><!DOCTYPE a><?pi x?><a/>", "<!DOCTYPE a [ ]><a/>",
        "<!DOCTYPE a>[<!ELEMENT a ANY>]><a/>", "<!DOCTYPE a [<!ENTITY e \"v\">]><a x=\"1&e;2\">x&e;y</a>",
        "<!DOCTYPE a [<!ENTITY e \"x<b>y</b>z\">]><r><a>1&e;2</a></r>",
        "<!DOCTYPE a [<!ENTITY e \"&#60;b/>\">]><a>&e;</a>",
        "<!DOCTYPE a [<!ENTITY e \"1&f;2\"><!ENTITY f \"F\">]><a>&e;</a>",
        "<!DOCTYPE a [<!ENTITY e \"1&g;2\">]><a>&e;</a>",
        "<!DOCTYPE a [<!ENTITY e \"v\"><!ENTITY e \"w\">]><a>&e;</a>",
        "<!DOCTYPE a [<!ENTITY lt \"&#38;#60;\">]><a>&lt;</a>",
        "<!DOCTYPE a [<!ENTITY lt \"<\">]><a/>", "<!DOCTYPE a [<!ENTITY e SYSTEM \"x.ent\">]><a>x&e;y</a>",
        "<!DOCTYPE a [<!ENTITY e SYSTEM \"x.ent\">]><a x=\"&e;\"/>", "<!DOCTYPE a [<!ENTITY e SYSTEM \"x#f\">]><a/>",
        "<!DOCTYPE a [<!ENTITY e SYSTEM \"x\" NDATA n>]><a>&e;</a>", "<!DOCTYPE a [<!ENTITY a:b \"v\">]><a/>",
        "<!DOCTYPE a [<!ENTITY e \"a%b\">]><a/>", "<!DOCTYPE a [<!ENTITY % p \"x\"> %p;]><a/>",
        "<!DOCTYPE a SYSTEM \"x\" [<!ENTITY % p \"<!ENTITY e 'v'>\"> %p;]><a>&e;</a>",
        "<!DOCTYPE a SYSTEM \"x\" [%u;]><a/>",
        "<!DOCTYPE a SYSTEM \"x\" [<!ENTITY e \"&f;\">]><a>&e;</a>",
        "<!DOCTYPE a SYSTEM \"x\" [<!ENTITY e \"v&f;\">]><a x=\"&e;\"/>",
        "<!DOCTYPE a [<!ELEMENT a ((b|c),d+,(e?,f)*)?><!ELEMENT b (#PCDATA)><!ELEMENT c EMPTY>]><a/>",
        "<!DOCTYPE a [<!ELEMENT a (b|c?)+><!ELEMENT b (x*)+><!ELEMENT c ((p,q),r)>]><a/>",
        "<!DOCTYPE a [<!ELEMENT a (b|c,d)>]><a/>", "<!DOCTYPE a [<!ELEMENT a (#PCDATA|b)>]><a/>",
        "<!DOCTYPE a [<!ELEMENT a (b) *>]><a/>", "<!DOCTYPE a [<!ELEMENT a FOO>]><a/>",
        "<!DOCTYPE a [<!ATTLIST a x CDATA #IMPLIED y ID #REQUIRED z NMTOKENS \" a  b \" w NOTATION (n) #IMPLIED>]><a/>",
        "<!DOCTYPE a [<!ATTLIST a x CDATA #IMPLIED><!ATTLIST a x ID #IMPLIED>]><a/>",
        "<!DOCTYPE a [<!ATTLIST a x ID #IMPLIED y ID #IMPLIED>]><a/>",
        "<!DOCTYPE a [<!ATTLIST a x NMTOKEN \"a b\">]><a/>",
        "<!DOCTYPE a [<!ATTLIST a x (p|p) #IMPLIED>]><a/>", "<!DOCTYPE a [<!ATTLIST a x CDATA \"a<b\">]><a/>",
        "<!DOCTYPE a [<!ATTLIST b id ID #IMPLIED t NMTOKENS #IMPLIED>]><a><b id=\" x \" t=\" p  q \"/><b id=\"x\"/></a>",
        "<!DOCTYPE a [<!ATTLIST b id ID #IMPLIED>]><a><b id=\"1\"/><b id=\"2\"/></a>",
        "<!DOCTYPE a [<!ATTLIST a xmlns:p CDATA #FIXED \"urn:p\">]><a><p:b/></a>",
        "<!DOCTYPE a [<!ATTLIST a xmlns CDATA #FIXED \"&quot;\">]><a/>",
        "<!DOCTYPE a [<!ATTLIST a xmlns:p CDATA #FIXED 'x\"y&lt;&amp;'>]><a/>",
        "<!DOCTYPE a [<!ATTLIST a b NMTOKENS \"&#9;x\">]><a b=\"&#9;y\"/>",
        "<!DOCTYPE a [<!ATTLIST a b (x|y) \"&#10;&#13; x y\">]><a/>",
        "<!DOCTYPE a [<!ATTLIST a b NMTOKEN \"&#9;x\">]><a/>",
        "<!DOCTYPE a [<!ATTLIST a b NMTOKENS \"x&#9;\">]><a/>", "<!DOCTYPE a [<!ATTLIST a b IDREFS \"&#9;x\">]><a/>",
        "<!DOCTYPE a [<!ATTLIST a ml:lang CDATA \"en\">]><a/>", "<!DOCTYPE a [<!NOTATION n PUBLIC \"p\">]><a/>",
        "<!DOCTYPE a [<!-- c --><?pi x?>]><a/>", "<!DOCTYPE a [<?pi \"x?>]><a/>",
        "<!DOCTYPE a [<?pi <!--><a/> ?>]><a/>", "<!DOCTYPE a [<!ATTLIST a :x CDATA \"1\">]><a/>",
        "<!DOCTYPE a [<!ATTLIST a q:-y CDATA #IMPLIED>]><a/>", "<!DOCTYPE a [<!ATTLIST a xmlns CDATA \"a b\">]><a/>",
        "<!DOCTYPE a [<!ATTLIST b xmlns: CDATA #FIXED \"urn:p\">]><a xmlns:p=\"urn:p\"><b/></a>",
        "<!DOCTYPE a [<!ENTITY e SYSTEM \"x\" NDATA >]><a/>", "<!DOCTYPE a SYSTEM \"x\"><a><b/> &nbsp; c<c/></a>",
        "<!DOCTYPE a [<!ENTITY x SYSTEM \"y.ent\">]><a><b/> &x; c<c/></a>",
        "<!DOCTYPE a SYSTEM \"x\" [<!ENTITY % p \"<!-- c -->\"> %p; %p;]><a/>",
        "<!DOCTYPE a SYSTEM \"x\" [<!ENTITY % p \"<!-- c -->\"> %p; <!-- x --> %p;]><a/>",
        "<!DOCTYPE a [<!ENTITY e \"v\" junk>]><a/>", "<!DOCTYPE a [junk]><a/>",
        // HTML and XHTML.
        "<html><br>x</br><BR/><hr><!--c--></hr><p/><embed/></html>", "<HTML><BODY><P>x</P></BODY></HTML>",
        "<html><input CHECKED=\"no\" readonly=\"\" hidden=\"\"/><a title=\"&quot;q&quot; &lt;&gt;\">t</a></html>",
        "<?pi x?><html><?pi y?><SCRIPT>a &lt; b</SCRIPT><p:script xmlns:p=\"urn:p\">a &lt; b</p:script></html>",
        "<!DOCTYPE html><html><p>x</p></html>", "<html xmlns=\"urn:other\"><br/></html>",
        "<p:html xmlns:p=\"urn:p\"><br/></p:html>",
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><FOO>x</FOO><o:BR xmlns:o=\"urn:o\"/><img src=\"a\">x</img></html>",
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><META HTTP-EQUIV=\"content-type\" content=\"x; CHARSET=KOI8-R\"/></head></html>",
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><meta http-equiv=\"Content-Type\" content=\"text/html\"/><meta http-equiv=\"Content-Type\" content=\"text/html; charset=KOI8-R\"/></head></html>",
        "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\"><html><br/></html>",
        "<!DOCTYPE html SYSTEM \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\"><html><br/></html>",
        "<?a?><!DOCTYPE html [<?pi x?><!-- c -->]><?b c?><html/>", "<!DOCTYPE html [<?pi?>]><html/>",
        "<!DOCTYPE html SYSTEM \"x\" [<!ENTITY % p \"<?pi y?>\"> %p;]><html/>",
        "<!DOCTYPE html [<?pi x?>]><html xmlns=\"http://www.w3.org/1999/xhtml\"/>",
        // Namespaces the DOCTYPE gives elements.
        "<!DOCTYPE r [<!ATTLIST e a CDATA \"zzz\" xmlns:q CDATA #FIXED \"urn:q\">]><r xmlns:q=\"urn:q\"><e/></r>",
        "<!DOCTYPE r [<!ATTLIST e a CDATA \"urn:q\" xmlns:q CDATA #FIXED \"urn:q\">]><r xmlns:q=\"urn:q\"><e/></r>",
        "<!DOCTYPE r [<!ATTLIST e xmlns:p CDATA #FIXED \"urn:p\" xmlns:q CDATA #FIXED \"urn:q\">]>"
            + "<r xmlns:p=\"urn:p\" xmlns:q=\"urn:q\"><e/></r>",
        "<!DOCTYPE r [<!ATTLIST e xmlns CDATA #FIXED \"\">]><r><e><e/></e></r>",
        "<!DOCTYPE r [<!ATTLIST e p:a CDATA \"urn:d\" s:a CDATA \"\" xmlns:s CDATA #FIXED \"\">]>"
            + "<r xmlns:p=\"urn:d\" xmlns:s=\"urn:d\"><e/></r>",
        "<!DOCTYPE r [<!ATTLIST e p:a CDATA \"urn:x\" s:a CDATA \"\" xmlns:s CDATA #FIXED \"\">]>"
            + "<r xmlns:p=\"urn:d\" xmlns:s=\"urn:d\"><e/></r>",
        "<!DOCTYPE r [<!ATTLIST e p:a CDATA \"1\" p:b CDATA \"2\">]><r xmlns:p=\"urn:p\"><e/><e p:a=\"3\"/></r>",
        // External entities' system IDs.
        "<!DOCTYPE a [<!ENTITY e SYSTEM \"\">]><a>&e;</a>", "<!DOCTYPE a [<!ENTITY e SYSTEM \"\">]><a/>",
        "<!DOCTYPE a [<!ENTITY e PUBLIC \"p\" \"\">]><a>&e;</a>",
        "<!DOCTYPE a [<!ENTITY e SYSTEM \"\"><!ENTITY f \"&e;\">]><a>&f;</a>",
        "<!DOCTYPE a [<!ENTITY e SYSTEM \"http://[::1#x]/\">]><a/>",
        "<!DOCTYPE a [<!ENTITY e SYSTEM \"h://[x]/#\">]><a/>",
    ]

    /// Content models nested 127 to 129 deep, since XMLParser refuses them past 128.
    static let deepContentModels: [String] = (127...129).flatMap { (depth: Int) -> [String] in
        let groups = String(repeating: "(", count: depth)
        return [
            "<!DOCTYPE a [<!ELEMENT a \(groups)b\(String(repeating: ")", count: depth))>]><a/>",
            "<!DOCTYPE a [<!ELEMENT a \(groups)b|c\(String(repeating: ")*", count: depth))>]><a/>",
        ]
    }
}
