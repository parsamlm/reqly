import Testing

@testable import LinuxDesktop

@Suite struct KConfigFileTests {
    static let proxy = ["Proxy Settings"]

    /// A `kioslaverc` such as KDE keeps, with other settings, comments and a translation.
    static let kioslaverc = """
        # Written by hand
        [Cache]
        CacheSize=5120

        [Proxy Settings]
        NoProxyFor=localhost,127.0.0.1
        ProxyType=0
        httpProxy[de]=http://proxy.example 3128

        [Proxy Settings][Authentication]
        httpProxy=not this one

        """

    @Test func readsKeysAsKDEDoes() {
        let file = KConfigFile(text: Self.kioslaverc)
        #expect(file.value("ProxyType", in: Self.proxy) == "0")
        #expect(file.value("NoProxyFor", in: Self.proxy) == "localhost,127.0.0.1")
        // A translation isn't the key, and neither is a subgroup's.
        #expect(file.value("httpProxy", in: Self.proxy) == nil)
        #expect(file.value("httpProxy", in: Self.proxy + ["Authentication"]) == "not this one")
        #expect(file.value("CacheSize", in: ["Cache"]) == "5120")
        #expect(!file.hasNoKeys)
    }

    @Test func changesOnlyItsOwnLines() {
        var file = KConfigFile(text: Self.kioslaverc)
        file.setValue("1", for: "ProxyType", in: Self.proxy)
        file.setValue("http://127.0.0.1 9090", for: "httpProxy", in: Self.proxy)
        #expect(
            file.text == """
                # Written by hand
                [Cache]
                CacheSize=5120

                [Proxy Settings]
                NoProxyFor=localhost,127.0.0.1
                ProxyType=1
                httpProxy[de]=http://proxy.example 3128
                httpProxy=http://127.0.0.1 9090

                [Proxy Settings][Authentication]
                httpProxy=not this one

                """)
        #expect(file.value("httpProxy", in: Self.proxy) == "http://127.0.0.1 9090")
    }

    @Test func putsTheFileBackAsItWas() {
        var file = KConfigFile(text: Self.kioslaverc)
        for (key, value) in [("ProxyType", "1"), ("httpProxy", "x"), ("httpsProxy", "y")] {
            file.setValue(value, for: key, in: Self.proxy)
        }
        file.setValue("0", for: "ProxyType", in: Self.proxy)
        file.removeValue("httpProxy", in: Self.proxy)
        file.removeValue("httpsProxy", in: Self.proxy)
        #expect(file.text == Self.kioslaverc)
    }

    @Test func addsTheGroupWhenTheFileHasNone() {
        let original = "[Cache]\nCacheSize=5120\n"
        var file = KConfigFile(text: original)
        file.setValue("1", for: "ProxyType", in: Self.proxy)
        file.setValue("http://127.0.0.1 9090", for: "httpProxy", in: Self.proxy)
        #expect(
            file.text == "[Cache]\nCacheSize=5120\n\n[Proxy Settings]\nProxyType=1\nhttpProxy=http://127.0.0.1 9090\n")
        // Taking the keys out takes the group out, and the blank line before it.
        file.removeValue("ProxyType", in: Self.proxy)
        file.removeValue("httpProxy", in: Self.proxy)
        #expect(file.text == original)
    }

    @Test func startsAMissingFile() {
        var file = KConfigFile(text: "")
        #expect(file.hasNoKeys)
        #expect(file.value("ProxyType", in: Self.proxy) == nil)
        file.setValue("1", for: "ProxyType", in: Self.proxy)
        #expect(file.text == "[Proxy Settings]\nProxyType=1\n")
        file.removeValue("ProxyType", in: Self.proxy)
        #expect(file.text == "")
        #expect(file.hasNoKeys)
    }

    @Test func leavesWindowsLineEndingsAsTheyAre() {
        let original = "[Cache]\r\nCacheSize=5120\r\n\r\n[Proxy Settings]\r\nProxyType=0\r\n"
        var file = KConfigFile(text: original)
        #expect(file.value("ProxyType", in: Self.proxy) == "0")
        file.setValue("1", for: "ProxyType", in: Self.proxy)
        file.setValue("x", for: "httpProxy", in: Self.proxy)
        #expect(file.text == "[Cache]\r\nCacheSize=5120\r\n\r\n[Proxy Settings]\r\nProxyType=1\r\nhttpProxy=x\r\n")
        file.setValue("0", for: "ProxyType", in: Self.proxy)
        file.removeValue("httpProxy", in: Self.proxy)
        #expect(file.text == original)
    }

    @Test func keepsAFileWithNoLineBreakAtTheEnd() {
        var file = KConfigFile(text: "[Proxy Settings]\nProxyType=0")
        file.setValue("1", for: "ProxyType", in: Self.proxy)
        #expect(file.text == "[Proxy Settings]\nProxyType=1")
        file.setValue("x", for: "httpProxy", in: Self.proxy)
        #expect(file.text == "[Proxy Settings]\nProxyType=1\nhttpProxy=x\n")
    }

    @Test func readsAndWritesEscapes() {
        let file = KConfigFile(text: "[G]\na = \\sspaced\\s \nb=back\\\\slash\\ttab\\x41\nc=list\\;item\n")
        #expect(file.value("a", in: ["G"]) == " spaced ")
        #expect(file.value("b", in: ["G"]) == "back\\slash\ttabA")
        #expect(file.value("c", in: ["G"]) == "list\\;item")

        var written = KConfigFile(text: "")
        written.setValue(" two\nlines\\ ", for: "k", in: ["G"])
        #expect(written.text == "[G]\nk=\\stwo\\nlines\\\\\\s\n")
        #expect(written.value("k", in: ["G"]) == " two\nlines\\ ")
    }

    @Test func readsTheLastOfARepeatedKeyAndReplacesThemAll() {
        var file = KConfigFile(text: "[Proxy Settings]\nProxyType=2\n[Other]\nx=1\n[Proxy Settings]\nProxyType=0\n")
        #expect(file.value("ProxyType", in: Self.proxy) == "0")
        file.setValue("1", for: "ProxyType", in: Self.proxy)
        #expect(file.text == "[Proxy Settings]\n[Other]\nx=1\n[Proxy Settings]\nProxyType=1\n")
    }

    @Test func seesLocks() {
        #expect(KConfigFile(text: "[$i]\n[Proxy Settings]\nProxyType=0\n").isLocked("ProxyType", in: Self.proxy))
        #expect(KConfigFile(text: "[Proxy Settings][$i]\nProxyType=0\n").isLocked("ProxyType", in: Self.proxy))
        #expect(KConfigFile(text: "[Proxy Settings]\nProxyType[$i]=0\n").isLocked("ProxyType", in: Self.proxy))
        #expect(!KConfigFile(text: "[Proxy Settings]\nProxyType[$i]=0\n").isLocked("httpProxy", in: Self.proxy))
        #expect(
            !KConfigFile(text: "[Cache][$i]\n[Proxy Settings]\nProxyType=0\n").isLocked("ProxyType", in: Self.proxy))
        // A key with options is still the key.
        #expect(KConfigFile(text: "[Proxy Settings]\nProxyType[$e]=1\n").value("ProxyType", in: Self.proxy) == "1")
    }
}
