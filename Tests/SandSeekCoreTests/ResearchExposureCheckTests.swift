import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
@testable import SandSeekCore

private func v6(_ groups: UInt16...) -> ResearchHostAddress {
    ResearchHostAddress.ipv6(groups: groups)!
}

/// Answers per address as told and remembers what it was asked. An address
/// that is not listed refuses, as a closed port on the Mac's own address does.
private final class FakeConnector: ResearchPortConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let accepting: Set<ResearchHostAddress>
    private let silent: Set<ResearchHostAddress>
    private let onlyPort: Int?
    private var asked: [ResearchHostAddress] = []
    private var timeouts: [TimeInterval] = []

    /// `accepting` accepts (on `onlyPort` if given); `silent` neither accepts
    /// nor refuses.
    init(accepting: Set<ResearchHostAddress> = [],
         silent: Set<ResearchHostAddress> = [],
         onlyPort: Int? = nil) {
        self.accepting = accepting
        self.silent = silent
        self.onlyPort = onlyPort
    }

    var askedAddresses: [ResearchHostAddress] { lock.withLock { asked } }
    var askedTimeouts: [TimeInterval] { lock.withLock { timeouts } }

    func answer(address: ResearchHostAddress, port: Int, timeout: TimeInterval) async
        -> ResearchPortAnswer {
        lock.withLock {
            asked.append(address)
            timeouts.append(timeout)
        }
        if accepting.contains(address), onlyPort == nil || onlyPort == port { return .accepted }
        return silent.contains(address) ? .unknown : .refused
    }
}

/// Accepts on loopback and refuses everywhere else, except that one address
/// stays silent on one port.
private struct PortSilentConnector: ResearchPortConnecting {
    let silentPort: Int
    let silent: ResearchHostAddress

    func answer(address: ResearchHostAddress, port: Int, timeout: TimeInterval) async
        -> ResearchPortAnswer {
        if address == .ipv4(127, 0, 0, 1) { return .accepted }
        return address == silent && port == silentPort ? .unknown : .refused
    }
}

/// A TCP listener on 127.0.0.1 and a port the system chose, to try the real
/// connector against.
private final class LocalListener {
    let port: Int
    private let descriptor: Int32

    init?() {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let made = socket(AF_INET, streamType, 0)
        guard made >= 0 else { return nil }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(made, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(made, 4) == 0 else {
            close(made)
            return nil
        }
        var named = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &named) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(made, generic, &length)
            }
        }
        guard result == 0 else {
            close(made)
            return nil
        }
        descriptor = made
        port = Int(UInt16(bigEndian: named.sin_port))
    }

    func stop() {
        close(descriptor)
    }
}

@Suite struct ResearchExposureCheckTests {
    // MARK: which addresses are tried

    @Test func loopbackLinkLocalAndSpecialAddressesAreSkipped() {
        let skipped: [ResearchHostAddress] = [
            .ipv4(127, 0, 0, 1), .ipv4(127, 1, 2, 3),
            .ipv4(169, 254, 10, 20), .ipv4(169, 254, 0, 1),
            .ipv4(0, 0, 0, 0), .ipv4(0, 1, 2, 3),
            .ipv4(224, 0, 0, 1), .ipv4(239, 255, 255, 250), .ipv4(255, 255, 255, 255),
            v6(0, 0, 0, 0, 0, 0, 0, 1),
            v6(0, 0, 0, 0, 0, 0, 0, 0),
            v6(0xfe80, 0, 0, 0, 0x1c2d, 0xaaaa, 0xbbbb, 0xcccc),
            v6(0xfebf, 0xffff, 0, 0, 0, 0, 0, 1),
            v6(0xff02, 0, 0, 0, 0, 0, 0, 1),
            // ::ffff:127.0.0.1 and ::ffff:169.254.1.1
            v6(0, 0, 0, 0, 0, 0xffff, 0x7f00, 0x0001),
            v6(0, 0, 0, 0, 0, 0xffff, 0xa9fe, 0x0101),
        ]
        for address in skipped {
            #expect(!address.isNetworkAddress, "\(address.text) should be skipped")
        }
    }

    @Test func addressesOtherMachinesCouldUseAreKept() {
        let kept: [ResearchHostAddress] = [
            .ipv4(192, 168, 1, 5), .ipv4(10, 0, 0, 2), .ipv4(172, 16, 5, 5),
            .ipv4(100, 64, 1, 1), .ipv4(192, 168, 64, 1), .ipv4(8, 8, 8, 8),
            .ipv4(169, 253, 1, 1), .ipv4(223, 255, 255, 255),
            v6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5),
            v6(0xfd12, 0x3456, 0x789a, 0, 0, 0, 0, 1),
            // Just outside fe80::/10, and the deprecated site-local range.
            v6(0xfe7f, 0, 0, 0, 0, 0, 0, 1), v6(0xfec0, 0, 0, 0, 0, 0, 0, 1),
            // ::ffff:192.168.1.5
            v6(0, 0, 0, 0, 0, 0xffff, 0xc0a8, 0x0105),
            // ::2 is not the loopback address.
            v6(0, 0, 0, 0, 0, 0, 0, 2),
        ]
        for address in kept {
            #expect(address.isNetworkAddress, "\(address.text) should be tried")
        }
    }

    @Test func theListIsFilteredWithoutDuplicatesAndSortedIPv4First() {
        let all: [ResearchHostAddress] = [
            v6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5),
            .ipv4(192, 168, 64, 1),
            .ipv4(127, 0, 0, 1),
            v6(0xfe80, 0, 0, 0, 1, 2, 3, 4),
            .ipv4(10, 0, 0, 7),
            .ipv4(192, 168, 64, 1),
            v6(0, 0, 0, 0, 0, 0, 0, 1),
            .ipv4(169, 254, 3, 4),
            v6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5),
            v6(0xfd00, 0, 0, 0, 0, 0, 0, 1),
        ]
        #expect(ResearchHostAddress.networkAddresses(from: all) == [
            .ipv4(10, 0, 0, 7), .ipv4(192, 168, 64, 1),
            v6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5), v6(0xfd00, 0, 0, 0, 0, 0, 0, 1),
        ])
        #expect(ResearchHostAddress.networkAddresses(from: []).isEmpty)
    }

    @Test func addressesCanOnlyBeMadeFromFourOrSixteenBytes() {
        #expect(ResearchHostAddress(bytes: [1, 2, 3]) == nil)
        #expect(ResearchHostAddress(bytes: Array(repeating: 0, count: 8)) == nil)
        #expect(ResearchHostAddress(bytes: [10, 0, 0, 1]) == .ipv4(10, 0, 0, 1))
        #expect(ResearchHostAddress.ipv6(groups: [1, 2, 3]) == nil)
        #expect(ResearchHostAddress(bytes: Array(repeating: 1, count: 16))?.isIPv6 == true)
    }

    @Test func addressesAreWrittenInTheUsualForm() {
        #expect(ResearchHostAddress.ipv4(192, 168, 1, 5).text == "192.168.1.5")
        #expect(v6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5).text == "2001:db8::5")
        #expect(v6(0, 0, 0, 0, 0, 0, 0, 1).text == "::1")
        #expect(v6(0, 0, 0, 0, 0, 0, 0, 0).text == "::")
        #expect(v6(0xfe80, 0, 0, 0, 0x1c2d, 0xaaaa, 0xbbbb, 0xcccc).text == "fe80::1c2d:aaaa:bbbb:cccc")
        #expect(v6(1, 2, 3, 4, 5, 6, 7, 8).text == "1:2:3:4:5:6:7:8")
        // A single zero group is not shortened; the first longest run is.
        #expect(v6(1, 0, 2, 3, 4, 5, 6, 7).text == "1:0:2:3:4:5:6:7")
        #expect(v6(1, 0, 0, 2, 0, 0, 0, 3).text == "1:0:0:2::3")
        #expect(v6(1, 0, 0, 2, 3, 0, 0, 4).text == "1::2:3:0:0:4")
        #expect(v6(0xfd00, 0, 0, 0, 0, 0, 0, 0).text == "fd00::")
        #expect(ResearchHostAddress.ipv4(192, 168, 1, 5).hostAndPort(8080) == "192.168.1.5:8080")
        #expect(v6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5).hostAndPort(8080) == "[2001:db8::5]:8080")
    }

    @Test func theSystemListHoldsOnlyAddressesThatAreWorthTrying() {
        // Whatever this machine has: none of it is loopback or link-local.
        let found = ResearchHostAddress.localNetworkAddresses()
        let ok = found.allSatisfy(\.isNetworkAddress)
        #expect(ok)
        #expect(Set(found).count == found.count)
    }

    // MARK: the check

    @Test func nothingAnsweringOnTheNetworkIsAllClear() async {
        let mac = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1)])
        let report = await ResearchExposureCheck.run(
            port: 8081, addresses: [mac], connector: connector)
        #expect(report.loopbackAnswered)
        #expect(report.checked == [mac])
        #expect(report.reachable.isEmpty)
        #expect(!report.isExposed)
        #expect(report.warning == nil)
    }

    @Test func anAddressThatAcceptsIsReportedWithTheWarning() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let bridge = ResearchHostAddress.ipv4(192, 168, 64, 1)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1), lan])
        let report = await ResearchExposureCheck.run(
            port: 8080, addresses: [bridge, lan], connector: connector)
        #expect(report.isExposed)
        #expect(report.reachable == [lan])
        // In numeric order, whatever order they were given in.
        #expect(report.checked == [lan, bridge])
        #expect(report.warning == "Something answers at 192.168.1.5:8080. "
            + "Other machines on that network can reach it. "
            + "Start the server so that it listens on 127.0.0.1 only "
            + "(llama-server: --host 127.0.0.1).")
        #expect(report.unknown.isEmpty)
        #expect(report.refusedCount == 1)
    }

    @Test func anAddressWithoutAnAnswerIsUnknownNeverClear() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let bridge = ResearchHostAddress.ipv4(192, 168, 64, 1)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1)], silent: [lan])
        let report = await ResearchExposureCheck.run(
            port: 8080, addresses: [bridge, lan], connector: connector)
        #expect(report.loopbackAnswered)
        #expect(!report.isExposed)
        #expect(report.warning == nil)
        #expect(report.unknown == [lan])
        #expect(report.hasUnknown)
        #expect(report.refusedCount == 1)
        let note = report.unknownNote ?? ""
        #expect(note.contains("Could not tell for 1 address (192.168.1.5:8080)"))
        #expect(note.contains("neither accepted nor refused"))
        #expect(note.contains("Local Network"))
    }

    @Test func aSilentLoopbackIsNotAnAnswerEither() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let connector = FakeConnector(silent: [.ipv4(127, 0, 0, 1)])
        let report = await ResearchExposureCheck.run(
            port: 8080, addresses: [lan], connector: connector)
        #expect(!report.loopbackAnswered)
    }

    @Test func severalAddressesAreAllNamedAndIPv6HasBrackets() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let global = v6(0x2001, 0xdb8, 0, 0, 0, 0, 0, 5)
        let connector = FakeConnector(accepting: [lan, global])
        let report = await ResearchExposureCheck.run(
            port: 8080, addresses: [global, lan], connector: connector)
        #expect(report.reachable == [lan, global])
        #expect(report.reachableText == "192.168.1.5:8080, [2001:db8::5]:8080")
        #expect(report.warning?.contains("answers at 192.168.1.5:8080, [2001:db8::5]:8080.") == true)
        // Nothing answered on loopback here: the report says so.
        #expect(!report.loopbackAnswered)
    }

    @Test func theServersPortIsTheOneThatIsTried() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let connector = FakeConnector(accepting: [lan], onlyPort: 8081)
        let other = await ResearchExposureCheck.run(
            port: 8080, addresses: [lan], connector: connector)
        #expect(!other.isExposed)
        let right = await ResearchExposureCheck.run(
            port: 8081, addresses: [lan], connector: connector)
        #expect(right.reachable == [lan])
        #expect(right.port == 8081)
    }

    @Test func loopbackAndLinkLocalAddressesAreNeverTriedOnTheNetworkList() async {
        let connector = FakeConnector()
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let report = await ResearchExposureCheck.run(
            port: 8080,
            addresses: [.ipv4(127, 0, 0, 1), .ipv4(169, 254, 1, 1),
                        v6(0xfe80, 0, 0, 0, 0, 0, 0, 1), v6(0, 0, 0, 0, 0, 0, 0, 1), lan],
            connector: connector, timeout: 0.25)
        #expect(report.checked == [lan])
        // Loopback is asked once, as the "is it running" probe; the others never.
        let asked = connector.askedAddresses
        #expect(asked.filter { $0 == lan }.count == 1)
        #expect(!asked.contains(.ipv4(169, 254, 1, 1)))
        #expect(!asked.contains(v6(0xfe80, 0, 0, 0, 0, 0, 0, 1)))
        #expect(connector.askedTimeouts.allSatisfy { $0 == 0.25 })
    }

    @Test func aMacWithoutNetworkAddressesHasNothingToTry() async {
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1)])
        let report = await ResearchExposureCheck.run(
            port: 8080, addresses: [], connector: connector)
        #expect(report.checked.isEmpty)
        #expect(!report.isExposed)
        #expect(report.loopbackAnswered)
    }

    // MARK: the command

    @Test func theCommandExitsZeroWhenNothingAnswersOnTheNetwork() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1)])
        let result = await ResearchExposureCommand.run(
            serverPort: 8080, sandboxPort: 9100, addresses: [lan], connector: connector)
        #expect(result.exitCode == 0)
        #expect(result.text.contains("Addresses tried: 192.168.1.5"))
        #expect(result.text.contains("RESULT: nothing answered on the network."))
        #expect(result.text.contains("answers on the network: no (all 1 address refused the connection)"))
        #expect(result.text.contains("Model server, port 8080:"))
        #expect(result.text.contains("Web sandbox, port 9100:"))
    }

    @Test func theCommandExitsThreeAndNamesTheAddress() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1), lan], onlyPort: 8080)
        let result = await ResearchExposureCommand.run(
            serverPort: 8080, sandboxPort: 9100, addresses: [lan], connector: connector)
        #expect(result.exitCode == 3)
        #expect(result.text.contains("answers on the network: YES, at 192.168.1.5:8080"))
        #expect(result.text.contains("RESULT: Something answers at 192.168.1.5:8080."))
        #expect(result.text.contains("llama-server: --host 127.0.0.1"))
    }

    @Test func anExposedSandboxAlsoExitsThree() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1), lan], onlyPort: 9100)
        let result = await ResearchExposureCommand.run(
            serverPort: 8080, sandboxPort: 9100, addresses: [lan], connector: connector)
        #expect(result.exitCode == 3)
        #expect(result.text.contains("the web sandbox is reachable from the network at 192.168.1.5:9100"))
    }

    @Test func aServerThatIsNotRunningGivesNoClearResult() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let result = await ResearchExposureCommand.run(
            serverPort: 8080, sandboxPort: 9100, addresses: [lan], connector: FakeConnector())
        #expect(result.exitCode == 4)
        #expect(result.text.contains("NO (the server is not running here)"))
        #expect(result.text.contains("RESULT: cannot tell."))
        // A stopped sandbox alone is not a reason to doubt the result.
        let sandboxOff = await ResearchExposureCommand.run(
            serverPort: 8080, sandboxPort: 9100, addresses: [lan],
            connector: FakeConnector(accepting: [.ipv4(127, 0, 0, 1)], onlyPort: 8080))
        #expect(sandboxOff.exitCode == 0)
        #expect(sandboxOff.text.contains("no (not running; that is fine)"))
    }

    @Test func aSilentAddressGivesExitFiveNotZero() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1)], silent: [lan])
        let result = await ResearchExposureCommand.run(
            serverPort: 8080, sandboxPort: 9100, addresses: [lan], connector: connector)
        #expect(result.exitCode == 5)
        #expect(result.text.contains("answers on the network: NOT KNOWN"))
        #expect(result.text.contains("RESULT: cannot tell. Could not tell for 1 address (192.168.1.5:8080)"))
        #expect(!result.text.contains("RESULT: nothing answered on the network."))
    }

    @Test func aSilentAddressOnTheSandboxPortAlsoGivesExitFive() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        // Accepts nothing but loopback, and stays silent only on 9100.
        let connector = PortSilentConnector(silentPort: 9100, silent: lan)
        let result = await ResearchExposureCommand.run(
            serverPort: 8080, sandboxPort: 9100, addresses: [lan], connector: connector)
        #expect(result.exitCode == 5)
        #expect(result.text.contains("(192.168.1.5:9100)"))
    }

    @Test func anExposedAddressStillWinsOverASilentOne() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let bridge = ResearchHostAddress.ipv4(192, 168, 64, 1)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1), lan], silent: [bridge])
        let result = await ResearchExposureCommand.run(
            serverPort: 8080, sandboxPort: 9100, addresses: [lan, bridge], connector: connector)
        #expect(result.exitCode == 3)
        #expect(result.text.contains("no clear answer from: 192.168.64.1:8080"))
    }

    // MARK: the real connector

    @Test func theRealConnectorSeesAListenerAndAClosedPort() async throws {
        let listener = try #require(LocalListener())
        let connector = ResearchTCPConnector()
        let open = await connector.answer(
            address: .ipv4(127, 0, 0, 1), port: listener.port, timeout: 2)
        #expect(open == .accepted)
        listener.stop()
        // A closed port on the Mac's own address is refused, which is
        // different from "no answer".
        let closed = await connector.answer(
            address: .ipv4(127, 0, 0, 1), port: listener.port, timeout: 2)
        #expect(closed == .refused)
    }

    @Test func theRealConnectorCannotTellForAnInvalidPort() async {
        let connector = ResearchTCPConnector()
        let zero = await connector.answer(address: .ipv4(127, 0, 0, 1), port: 0, timeout: 1)
        let tooHigh = await connector.answer(address: .ipv4(127, 0, 0, 1), port: 70_000, timeout: 1)
        #expect(zero == .unknown)
        #expect(tooHigh == .unknown)
    }

    @Test func theRealCheckFindsNoLoopbackListenerOnAFreePort() async throws {
        // End to end with the real connector and the real address list: a
        // port nobody listens on is reported as not running, not as exposed.
        let listener = try #require(LocalListener())
        let free = listener.port
        listener.stop()
        let report = await ResearchExposureCheck.run(port: free, timeout: 1)
        #expect(!report.loopbackAnswered)
        #expect(!report.isExposed)
    }
}

@Suite struct ResearchCheckExposureArgumentTests {
    @Test func theOptionNeedsNoQuestionAndTakesTheTwoAddresses() throws {
        let parsed = try ResearchArguments.parse(["--check-exposure"], environment: [:])
        #expect(parsed.checkExposure)
        #expect(parsed.question.isEmpty)
        let both = try ResearchArguments.parse(
            ["--check-exposure", "--server", "http://127.0.0.1:8081",
             "--sandbox", "http://127.0.0.1:9100"], environment: [:])
        #expect(both.checkExposure)
        #expect(both.serverURL.port == 8081)
        let quiet = try ResearchArguments.parse(["--check-exposure", "--quiet"], environment: [:])
        #expect(quiet.checkExposure)
        #expect(quiet.quiet)
        let plain = try ResearchArguments.parse(["q"], environment: [:])
        #expect(!plain.checkExposure)
        #expect(ResearchArguments.usage.contains("--check-exposure"))
    }

    @Test func itDoesNotMixWithARunOrAReplay() {
        for arguments in [["--check-exposure", "a question"],
                          ["--check-exposure", "--model", "x"],
                          ["--check-exposure", "--server-type", "llamacpp"],
                          ["--check-exposure", "--output", "/tmp/never"],
                          ["--check-exposure", "--replay-figures", "/tmp/never.json"]] {
            #expect(throws: ResearchArgumentError.self, "\(arguments)") {
                _ = try ResearchArguments.parse(arguments, environment: [:])
            }
        }
    }

    @Test func aQuestionStillNeedsAQuestionWithoutTheOption() {
        #expect(throws: ResearchArgumentError.self) {
            _ = try ResearchArguments.parse(["--server", "http://127.0.0.1:8080"], environment: [:])
        }
    }
}

@Suite struct ResearchOllamaExposureTests {
    @Test func ollamasPortIsCheckedLikeAnyOtherAndGetsOllamasAdvice() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1), lan])
        let report = await ResearchExposureCheck.run(
            port: 11_434, addresses: [lan], connector: connector)
        #expect(report.isExposed)
        #expect(report.reachable == [lan])
        let warning = report.warning(for: .ollama)
        #expect(warning == "Something answers at 192.168.1.5:11434. "
            + "Other machines on that network can reach it. "
            + "Start Ollama with OLLAMA_HOST=127.0.0.1:11434 so that it listens on 127.0.0.1 only.")
        // Never the address that means every interface.
        #expect(warning?.contains("0.0.0.0") == false)
        // The advice for the other servers is unchanged.
        #expect(report.warning == report.warning(for: nil))
        #expect(report.warning(for: .llamacpp) == report.warning)
        #expect(report.warning?.contains("llama-server: --host 127.0.0.1") == true)
    }

    @Test func nothingIsSaidWhenNothingAnswersOnTheNetwork() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1)])
        let report = await ResearchExposureCheck.run(
            port: 11_434, addresses: [lan], connector: connector)
        #expect(report.warning(for: .ollama) == nil)
    }

    @Test func theCommandsResultCarriesTheAdviceOfTheKindItWasGiven() async {
        let lan = ResearchHostAddress.ipv4(192, 168, 1, 5)
        let connector = FakeConnector(accepting: [.ipv4(127, 0, 0, 1), lan], onlyPort: 11_434)
        let ollama = await ResearchExposureCommand.run(
            serverPort: 11_434, sandboxPort: 9_100, addresses: [lan], connector: connector,
            serverKind: .ollama)
        #expect(ollama.exitCode == ResearchExposureCommand.exitExposed)
        #expect(ollama.text.contains("RESULT: Something answers at 192.168.1.5:11434."))
        #expect(ollama.text.contains("OLLAMA_HOST=127.0.0.1:11434"))
        #expect(!ollama.text.contains("llama-server"))
        let other = await ResearchExposureCommand.run(
            serverPort: 11_434, sandboxPort: 9_100, addresses: [lan], connector: connector)
        #expect(other.text.contains("llama-server: --host 127.0.0.1"))
        #expect(!other.text.contains("OLLAMA_HOST"))
    }

    @Test func theUsageNamesOllamasAdvice() {
        #expect(ResearchArguments.usage.contains("OLLAMA_HOST=127.0.0.1:11434"))
    }
}
