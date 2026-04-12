import XCTest
@testable import AgentBooth

final class ScriptCommandBuilderTests: XCTestCase {
    func testCodexCommandIncludesModelFlag() throws {
        var settings = AppSettings()
        settings.scriptCLIKind = .codex
        settings.scriptCLIModel = "gpt-5.4"

        let builder = ScriptCommandBuilder()
        let command = try builder.makeCommand(prompt: "hello", settings: settings)

        XCTAssertEqual(command, ["codex", "exec", "--skip-git-repo-check", "--model=gpt-5.4", "hello"])
    }

    func testClaudeCommandKeepsPromptAndModel() throws {
        var settings = AppSettings()
        settings.scriptCLIKind = .claude
        settings.scriptCLIModel = "sonnet"

        let builder = ScriptCommandBuilder()
        let command = try builder.makeCommand(prompt: "intro", settings: settings)

        XCTAssertEqual(command, ["claude", "-p", "intro", "--output-format", "text", "--model", "sonnet"])
    }

    func testProcessEnvironmentAppendsHomebrewAndUsrLocalPaths() {
        let builder = ScriptProcessEnvironmentBuilder()
        let environment = builder.makeEnvironment(baseEnvironment: ["PATH": "/usr/bin:/bin"])
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)

        XCTAssertTrue(pathEntries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(pathEntries.contains("/usr/local/bin"))
        XCTAssertTrue(pathEntries.starts(with: ["/usr/bin", "/bin"]))
    }

    func testLaunchBuilderResolvesExecutableFromAugmentedPath() throws {
        let builder = ScriptProcessLaunchBuilder()
        let launchSpec = try builder.makeLaunchSpec(
            command: ["echo", "hello"],
            environment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertTrue(["/usr/bin/echo", "/bin/echo"].contains(launchSpec.executableURL.path))
        XCTAssertEqual(launchSpec.arguments, ["hello"])
    }

    func testLaunchBuilderFallsBackToLoginShellWhenExecutableIsMissing() throws {
        let builder = ScriptProcessLaunchBuilder()
        let launchSpec = try builder.makeLaunchSpec(
            command: ["claude", "-p", "hello world"],
            environment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(launchSpec.executableURL.path, "/bin/zsh")
        XCTAssertEqual(launchSpec.arguments.first, "-lc")
        XCTAssertEqual(launchSpec.arguments.count, 2)
        XCTAssertEqual(launchSpec.arguments[1], "'claude' '-p' 'hello world'")
    }
}
