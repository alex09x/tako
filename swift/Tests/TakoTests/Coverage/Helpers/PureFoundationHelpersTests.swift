import Testing
import Foundation
@testable import Tako

// MARK: AnySortKey

@MainActor
struct AnySortKeyTests {
    @Test func lessThanOrdersAscending() {
        #expect(AnySortKey(1) < AnySortKey(2))
        #expect(!(AnySortKey(2) < AnySortKey(1)))
    }

    @Test func equalWhenValuesMatch() {
        #expect(AnySortKey(5) == AnySortKey(5))
        #expect(!(AnySortKey(5) == AnySortKey(6)))
    }

    @Test func sortsArrayOfHeterogeneousComparableValues() {
        let values = [AnySortKey(3), AnySortKey(1), AnySortKey(2)]
        let sorted = values.sorted()
        #expect(sorted == [AnySortKey(1), AnySortKey(2), AnySortKey(3)])
    }

    @Test func comparingDifferentUnderlyingTypesTreatsAsEqual() {
        // The comparator casts both sides to the LHS's concrete type; when the
        // cast on the RHS fails it falls back to .orderedSame.
        let intKey = AnySortKey(1)
        let stringKey = AnySortKey("a")
        #expect(!(intKey < stringKey))
        #expect(intKey == stringKey)
    }
}

// MARK: AppInfo

@MainActor
struct AppInfoTests {
    @Test func returnsFalseWhenNotRunningInXcode() {
        // The test binary is launched via `swift test`, not Xcode, so the
        // Xcode-only environment variable is absent and this must be false.
        #expect(isRunningInXcode() == false)
    }
}

// MARK: Weak

@MainActor
struct WeakTests {
    private final class Box {}

    @Test func holdsValueWhileStrongReferenceExists() {
        let box = Box()
        let weak = Weak(box)
        #expect(weak.value === box)
    }

    @Test func clearsWhenUnderlyingObjectDeallocates() {
        var box: Box? = Box()
        let weak = Weak(box)
        #expect(weak.value != nil)
        box = nil
        #expect(weak.value == nil)
    }

    @Test func defaultsToNil() {
        let weak = Weak<Box>()
        #expect(weak.value == nil)
    }
}

// MARK: Array+Extension

@MainActor
struct ArrayExtensionTests {
    @Test func safeSubscriptReturnsElementInBounds() {
        let array = [10, 20, 30]
        #expect(array[safe: 1] == 20)
    }

    @Test func safeSubscriptReturnsNilOutOfBounds() {
        let array = [10, 20, 30]
        #expect(array[safe: -1] == nil)
        #expect(array[safe: 3] == nil)
    }

    @Test func indexWrappingBeforeWrapsAtStart() {
        let array = [1, 2, 3]
        #expect(array.indexWrapping(before: 0) == 2)
        #expect(array.indexWrapping(before: 2) == 1)
    }

    @Test func indexWrappingAfterWrapsAtEnd() {
        let array = [1, 2, 3]
        #expect(array.indexWrapping(after: 2) == 0)
        #expect(array.indexWrapping(after: 0) == 1)
    }

    @Test func withCStringsHandlesEmptyArray() {
        let strings: [String] = []
        let result = strings.withCStrings { pointers in pointers.count }
        #expect(result == 0)
    }

    @Test func withCStringsProvidesEveryPointerInOrder() {
        let strings = ["alpha", "beta", "gamma"]
        let decoded = strings.withCStrings { pointers -> [String] in
            pointers.map { ptr in
                guard let ptr else { return "" }
                return String(cString: ptr)
            }
        }
        #expect(decoded == strings)
    }
}

// MARK: Double+Extension

@MainActor
struct DoubleExtensionTests {
    @Test func clampedKeepsValueInsideRange() {
        #expect((0.5).clamped(to: 0...1) == 0.5)
    }

    @Test func clampedFloorsBelowRange() {
        #expect((-1.0).clamped(to: 0...1) == 0)
    }

    @Test func clampedCeilsAboveRange() {
        #expect((2.0).clamped(to: 0...1) == 1)
    }
}

// MARK: Duration+Extension

@MainActor
struct DurationExtensionTests {
    @Test func timeIntervalConvertsWholeSeconds() {
        #expect(Duration.seconds(3).timeInterval == 3.0)
    }

    @Test func timeIntervalConvertsSubsecondComponents() {
        let interval = Duration.milliseconds(500).timeInterval
        #expect(abs(interval - 0.5) < 0.0001)
    }

    @Test func timeIntervalHandlesZero() {
        #expect(Duration.zero.timeInterval == 0)
    }
}

// MARK: ObjectIdentifier+Extension

@MainActor
struct ObjectIdentifierExtensionTests {
    private final class Box {}

    @Test func hexStringMatchesRadix16Rendering() {
        let box = Box()
        let id = ObjectIdentifier(box)
        let expected = String(UInt(bitPattern: id), radix: 16)
        #expect(id.hexString == expected)
    }

    @Test func hexStringIsStableForSameInstance() {
        let box = Box()
        let id = ObjectIdentifier(box)
        #expect(id.hexString == id.hexString)
    }
}

// MARK: Optional+Extension

@MainActor
struct OptionalStringExtensionTests {
    @Test func withCStringPassesValueWhenPresent() {
        let optional: String? = "hello"
        let decoded = optional.withCString { ptr -> String? in
            guard let ptr else { return nil }
            return String(cString: ptr)
        }
        #expect(decoded == "hello")
    }

    @Test func withCStringPassesNilWhenAbsent() {
        let optional: String? = nil
        let sawNil = optional.withCString { ptr in ptr == nil }
        #expect(sawNil)
    }
}

// MARK: String+Extension

@MainActor
struct StringExtensionTests {
    @Test func truncateLeavesShortStringsUntouched() {
        #expect("hi".truncate(length: 10) == "hi")
    }

    @Test func truncateShortensLongStringsWithEllipsis() {
        let result = "abcdefghij".truncate(length: 5)
        #expect(result == "abcd…")
        #expect(result.count == 5)
    }

    @Test func truncateWithCustomTrailing() {
        let result = "abcdefghij".truncate(length: 6, trailing: "...")
        #expect(result == "abc...")
    }

    @Test func truncateWithZeroBudgetReturnsOriginal() {
        // maxLength <= 0 (length shorter than the trailing marker) bails out.
        let result = "abcdef".truncate(length: 1)
        #expect(result == "abcdef")
    }

    @Test func truncateOnEmptyStringReturnsEmpty() {
        #expect("".truncate(length: 5) == "")
    }

    @Test func temporaryFileWritesContentsToDisk() throws {
        let contents = "helpers coverage test"
        let url = contents.temporaryFile("coverage-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == contents)
        #expect(url.pathExtension == "txt")
    }

    @Test func abbreviatedPathReplacesHomeDirectoryPrefix() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = home + "/Documents/file.txt"
        #expect(path.abbreviatedPath == "~/Documents/file.txt")
    }

    @Test func abbreviatedPathLeavesUnrelatedPathsUntouched() {
        let path = "/tmp/somewhere/file.txt"
        #expect(path.abbreviatedPath == path)
    }

    @Test func fourCharCodeEncodesASCIIBytes() {
        #expect("abcd".fourCharCode == 0x61626364)
    }

    @Test func fourCharCodeHandlesShorterStrings() {
        #expect("a".fourCharCode == 0x61)
    }
}

// MARK: UUID+Extension

@MainActor
struct UUIDExtensionTests {
    @Test func initializesFromCFUUID() {
        guard let cfuuid = CFUUIDCreate(nil) else {
            Issue.record("Expected CFUUIDCreate to succeed")
            return
        }
        let uuid = UUID(cfuuid)
        #expect(uuid != nil)

        let expectedString = CFUUIDCreateString(nil, cfuuid) as String
        #expect(uuid?.uuidString == expectedString)
    }
}

// MARK: FileHandle+Extension

@MainActor
struct FileHandleExtensionTests {
    @Test func writeStringAppendsUTF8DataToFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("filehandle-coverage-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var stream: FileHandle = handle
        print("hello stream", to: &stream)

        try handle.synchronize()
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written == "hello stream\n")
    }
}
