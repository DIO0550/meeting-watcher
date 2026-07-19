import Foundation
import Testing

@Suite("Dependency boundary script")
struct DependencyBoundaryScriptTests {
    @Test func currentProjectPassesDependencyBoundaryCheck() throws {
        let result = try runScript(root: repositoryRoot())

        #expect(result.terminationStatus == 0)
        #expect(!result.stderr.contains("error:"))
    }

    @Test func forbiddenMeetingSignalImportsFail() throws {
        let importVariants = [
            "import MeetingSignal",
            "@testable import MeetingSignal",
            "@_implementationOnly import MeetingSignal",
            "@_exported import MeetingSignal",
            "#if DEBUG\nimport MeetingSignal\n#endif",
        ]

        for importVariant in importVariants {
            let fixture = try DependencyFixture.makeClean()
            try fixture.writeForbiddenSource(
                "meeting-watcher/meeting-watcher/Forbidden.swift",
                contents: importVariant
            )

            let result = try fixture.runCheck()

            #expect(result.terminationStatus != 0)
            #expect(result.stderr.contains("MeetingSignal import is forbidden"))
            #expect(result.stdout.contains("Forbidden.swift"))
        }
    }

    @Test func appUnitTestMeetingSignalImportFails() throws {
        let fixture = try DependencyFixture.makeClean()
        try fixture.writeForbiddenSource(
            "meeting-watcher/meeting-watcherTests/ForbiddenTests.swift",
            contents: "import Testing\n@testable import MeetingSignal"
        )

        let result = try fixture.runCheck()

        #expect(result.terminationStatus != 0)
        #expect(result.stderr.contains("MeetingSignal import is forbidden"))
        #expect(result.stdout.contains("ForbiddenTests.swift"))
    }

    @Test func forbiddenFrameworkLinksFailForAppAndAppTests() throws {
        let cases: [(target: String, expected: String)] = [
            ("meeting-watcher", "target meeting-watcher must not link MeetingSignal.framework"),
            ("meeting-watcherTests", "target meeting-watcherTests must not link MeetingSignal.framework"),
        ]

        for testCase in cases {
            let fixture = try DependencyFixture.makeProjectFixture(frameworkLinkTarget: testCase.target)
            let result = try fixture.runCheck()

            #expect(result.terminationStatus != 0)
            #expect(result.stderr.contains(testCase.expected))
        }
    }

    @Test func forbiddenTargetDependenciesFailForAppAndAppTests() throws {
        let cases: [(target: String, expected: String)] = [
            ("meeting-watcher", "target meeting-watcher must not depend on MeetingSignal"),
            ("meeting-watcherTests", "target meeting-watcherTests must not depend on MeetingSignal"),
        ]

        for testCase in cases {
            let fixture = try DependencyFixture.makeProjectFixture(targetDependencyTarget: testCase.target)
            let result = try fixture.runCheck()

            #expect(result.terminationStatus != 0)
            #expect(result.stderr.contains(testCase.expected))
        }
    }

    @Test func allowedMeetingSignalTestDependencyDoesNotFail() throws {
        let fixture = try DependencyFixture.makeClean()
        try fixture.writeText(
            "README.md",
            contents: "MeetingSignal.framework is documented here and should not fail."
        )

        let result = try fixture.runCheck()

        #expect(result.terminationStatus == 0)
        #expect(!result.stderr.contains("must not link"))
        #expect(!result.stderr.contains("must not depend"))
        #expect(!result.stderr.contains("MeetingSignal import is forbidden"))
    }

    @Test func runScriptPhasePrecedesSourcesInAppTarget() throws {
        let project = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("meeting-watcher/meeting-watcher.xcodeproj/project.pbxproj"))
        let targetBlock = try #require(nativeTargetBlock(named: "meeting-watcher", in: project))
        let checkIndex = try #require(targetBlock.range(of: "/* MeetingSignal依存境界チェック */"))
        let sourcesIndex = try #require(targetBlock.range(of: "/* ソース */"))

        #expect(checkIndex.lowerBound < sourcesIndex.lowerBound)
    }
}

private struct DependencyFixture {
    let root: URL

    static func makeClean() throws -> DependencyFixture {
        try makeProjectFixture()
    }

    static func makeProjectFixture(
        frameworkLinkTarget: String? = nil,
        targetDependencyTarget: String? = nil
    ) throws -> DependencyFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-watcher-dependency-fixture-")
            .appendingPathComponent(UUID().uuidString)
        let fixture = DependencyFixture(root: root)
        try fixture.writeText(
            "meeting-watcher/meeting-watcher/ContentView.swift",
            contents: "import SwiftUI\nstruct ContentView {}\n"
        )
        try fixture.writeText(
            "meeting-watcher/meeting-watcherTests/meeting_watcherTests.swift",
            contents: "import Testing\n@testable import meeting_watcher\n"
        )
        try fixture.writeProjectFile(projectFile(
            frameworkLinkTarget: frameworkLinkTarget,
            targetDependencyTarget: targetDependencyTarget
        ))
        return fixture
    }

    func writeForbiddenSource(_ relativePath: String, contents: String) throws {
        try writeText(relativePath, contents: contents)
    }

    func writeProjectFile(_ contents: String) throws {
        try writeText("meeting-watcher/meeting-watcher.xcodeproj/project.pbxproj", contents: contents)
    }

    func writeText(_ relativePath: String, contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func runCheck() throws -> ScriptResult {
        try runScript(root: root)
    }
}

private struct ScriptResult {
    let terminationStatus: Int32
    let stdout: String
    let stderr: String
}

private func runScript(root: URL) throws -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [repositoryRoot().appendingPathComponent("scripts/check-meeting-signal-dependency.sh").path]
    process.environment = ["REPO_ROOT": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    return ScriptResult(
        terminationStatus: process.terminationStatus,
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func nativeTargetBlock(named name: String, in text: String) -> String? {
    var searchStart = text.startIndex
    while let isa = text.range(of: "isa = PBXNativeTarget;", range: searchStart..<text.endIndex) {
        guard let objectMarker = text[..<isa.lowerBound].range(of: " = {", options: .backwards) else {
            searchStart = isa.upperBound
            continue
        }
        let objectStart = text[..<objectMarker.lowerBound].lastIndex(of: "\n").map(text.index(after:)) ?? text.startIndex
        guard let objectEnd = text.range(of: "\n\t\t};", range: isa.upperBound..<text.endIndex) else {
            return nil
        }
        let candidate = String(text[objectStart..<objectEnd.upperBound])
        if candidate.contains("name = \"\(name)\";") || candidate.contains("name = \(name);") {
            return candidate
        }
        searchStart = objectEnd.upperBound
    }
    return nil
}

private func projectFile(frameworkLinkTarget: String?, targetDependencyTarget: String?) -> String {
    let appFrameworkFiles = frameworkLinkTarget == "meeting-watcher" ? "\n\t\t\t\t4D1800160000000000000018 /* MeetingSignal.framework（フレームワーク内） */," : ""
    let appTestsFrameworkFiles = frameworkLinkTarget == "meeting-watcherTests" ? "\n\t\t\t\t4D1800160000000000000018 /* MeetingSignal.framework（フレームワーク内） */," : ""
    let appDependencies = targetDependencyTarget == "meeting-watcher" ? "\n\t\t\t\t4D18001B0000000000000018 /* ターゲット依存関係 */," : ""
    let appTestsDependencies = targetDependencyTarget == "meeting-watcherTests" ? "\n\t\t\t\t4D18001B0000000000000018 /* ターゲット依存関係 */," : ""

    return """
// !$*UTF8*$!
{
\tarchiveVersion = 1;
\tclasses = {};
\tobjectVersion = 77;
\tobjects = {
\t\t4D1800160000000000000018 /* MeetingSignal.framework（フレームワーク内） */ = {isa = PBXBuildFile; fileRef = 4D1800070000000000000018 /* MeetingSignal.framework */; };
\t\t4D1800070000000000000018 /* MeetingSignal.framework */ = {isa = PBXFileReference; explicitFileType = wrapper.framework; path = MeetingSignal.framework; sourceTree = BUILT_PRODUCTS_DIR; };
\t\t4D18001A0000000000000018 /* コンテナ項目プロキシ */ = {
\t\t\tisa = PBXContainerItemProxy;
\t\t\tremoteGlobalIDString = 4D1800010000000000000018;
\t\t\tremoteInfo = MeetingSignal;
\t\t};
\t\t3AC63B162FE6093600F49D5D /* フレームワーク */ = {
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tfiles = (
\t\t\t\(appFrameworkFiles)
\t\t\t);
\t\t};
\t\t3AC63B232FE6093A00F49D5D /* フレームワーク */ = {
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tfiles = (
\t\t\t\(appTestsFrameworkFiles)
\t\t\t);
\t\t};
\t\t4D1800140000000000000018 /* フレームワーク */ = {
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tfiles = (
\t\t\t\t4D1800160000000000000018 /* MeetingSignal.framework（フレームワーク内） */,
\t\t\t);
\t\t};
\t\t3AC63B152FE6093600F49D5D /* ソース */ = { isa = PBXSourcesBuildPhase; files = (); };
\t\t3AC63B222FE6093A00F49D5D /* ソース */ = { isa = PBXSourcesBuildPhase; files = (); };
\t\t4D1800130000000000000018 /* ソース */ = { isa = PBXSourcesBuildPhase; files = (); };
\t\t3AC63B182FE6093600F49D5D /* meeting-watcher */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildPhases = (
\t\t\t\t3AC63B152FE6093600F49D5D /* ソース */,
\t\t\t\t3AC63B162FE6093600F49D5D /* フレームワーク */,
\t\t\t);
\t\t\tdependencies = (
\t\t\t\(appDependencies)
\t\t\t);
\t\t\tname = "meeting-watcher";
\t\t};
\t\t3AC63B252FE6093A00F49D5D /* meeting-watcherTests */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildPhases = (
\t\t\t\t3AC63B222FE6093A00F49D5D /* ソース */,
\t\t\t\t3AC63B232FE6093A00F49D5D /* フレームワーク */,
\t\t\t);
\t\t\tdependencies = (
\t\t\t\(appTestsDependencies)
\t\t\t);
\t\t\tname = "meeting-watcherTests";
\t\t};
\t\t4D1800010000000000000018 /* MeetingSignal */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildPhases = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = MeetingSignal;
\t\t};
\t\t4D1800110000000000000018 /* MeetingSignalTests */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildPhases = (
\t\t\t\t4D1800130000000000000018 /* ソース */,
\t\t\t\t4D1800140000000000000018 /* フレームワーク */,
\t\t\t);
\t\t\tdependencies = (
\t\t\t\t4D18001B0000000000000018 /* ターゲット依存関係 */,
\t\t\t);
\t\t\tname = MeetingSignalTests;
\t\t};
\t\t4D18001B0000000000000018 /* ターゲット依存関係 */ = {
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = 4D1800010000000000000018 /* MeetingSignal */;
\t\t\ttargetProxy = 4D18001A0000000000000018 /* コンテナ項目プロキシ */;
\t\t};
\t};
}
"""
}
