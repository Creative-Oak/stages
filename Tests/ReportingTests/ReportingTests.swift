import Foundation
import Testing
@testable import Reporting

@Suite struct RedactorTests {
  @Test func homeBecomesTilde() {
    #expect(Redactor.redact("/Users/magnus/Applications/Stages.app/Contents/MacOS/Stages", home: "/Users/magnus")
      == "~/Applications/Stages.app/Contents/MacOS/Stages")
  }

  @Test func onlyWholeComponentsOfHomeMatch() {
    #expect(Redactor.redact("/Users/magnus2/x", home: "/Users/magnus") == "/Users/<user>/x")
  }

  @Test func otherUsersAndVolumesArePlaceholders() {
    #expect(Redactor.redact("file:///Users/someone/Documents/Secret plan.pdf", home: "/Users/magnus")
      == "file:///Users/<user>/Documents/Secret plan.pdf")
    #expect(Redactor.redact("/Volumes/Client Work/x", home: "/Users/magnus") == "/Volumes/<volume>/x")
  }

  @Test func systemPathsAreLeftAlone() {
    let s = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
    #expect(Redactor.redact(s, home: "/Users/magnus") == s)
  }
}

@Suite struct ErrorSummaryTests {
  private struct Thing: Decodable { var name: String; var count: Int }

  @Test func decodingErrorsGiveThePathNotTheValue() {
    let data = Data(#"{"name": "Client Project X", "count": "lots"}"#.utf8)
    do {
      _ = try JSONDecoder().decode(Thing.self, from: data)
      Issue.record("expected a decoding error")
    } catch {
      let s = ErrorSummary.describe(error)
      #expect(s == "DecodingError.typeMismatch at count")
      #expect(!s.contains("lots") && !s.contains("Client"))
    }
  }

  @Test func nsErrorsGiveDomainAndCodeOnly() {
    let underlying = NSError(domain: NSPOSIXErrorDomain, code: 28)
    let e = NSError(domain: NSCocoaErrorDomain, code: 640, userInfo: [
      NSFilePathErrorKey: "/Users/magnus/Library/Application Support/Stages/state.json",
      NSUnderlyingErrorKey: underlying,
    ])
    #expect(ErrorSummary.describe(e) == "NSCocoaErrorDomain 640 (underlying NSPOSIXErrorDomain 28)")
  }
}
