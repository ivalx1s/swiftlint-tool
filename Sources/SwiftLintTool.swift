import Foundation
import ArgumentParser

@main
struct SwiftLintTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A Swift command-line tool to run SwiftLint on changed files.",
        subcommands: [Precommit.self, Prebuild.self],
        defaultSubcommand: Precommit.self
    )
    
    // Actor to manage the exit code safely in concurrent environments
    actor ExitCodeManager {
        private var exitCode: Int32 = 0
        
        func update(exitCode: Int32) {
            if exitCode != 0 {
                self.exitCode = exitCode
            }
        }
        
        func getExitCode() -> Int32 {
            return exitCode
        }
    }
    
    struct Precommit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run SwiftLint for pre-commit hook.")
        
        func run() async throws {
            print("Starting Precommit run")
            print("Current working directory: \(FileManager.default.currentDirectoryPath)")
            
            let exitCodeManager = ExitCodeManager()
            SwiftLintTool.exportPath()
            
            print("Checking if SwiftLint is installed...")
            if await SwiftLintTool.isSwiftLintInstalled() {
                print("SwiftLint is installed")
                // Run for staged files (including newly created files)
                print("Getting Git diff filenames...")
                let filenames = try await SwiftLintTool.getGitDiffFilenames(cached: true)
                print("Files to lint: \(filenames)")
                await SwiftLintTool.runSwiftLint(on: filenames, withArgs: ["--force-exclude"], pathPrefix: "./", exitCodeManager: exitCodeManager)
            } else {
                print("warning: SwiftLint not installed, download from https://github.com/realm/SwiftLint")
            }
            let code = await exitCodeManager.getExitCode()
            print("Final exit code: \(code)")
            SwiftLintTool.exit(withError: code == 0 ? nil : ExitCode(code))
        }
    }

    
    struct Prebuild: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run SwiftLint for pre-build script.")
        
        func run() async throws {
            let exitCodeManager = ExitCodeManager()
            SwiftLintTool.exportPath()
            
            if await SwiftLintTool.isSwiftLintInstalled() {
                // Run for unstaged files
                let unstagedFiles = try await SwiftLintTool.getGitDiffFilenames(cached: false, additionalArgs: ["../*.swift"])
                await SwiftLintTool.runSwiftLint(on: unstagedFiles, withArgs: ["--config", "../.swiftlint.yml", "--force-exclude"], pathPrefix: "../", exitCodeManager: exitCodeManager)
                
                // Run for staged files (including newly created files)
                let stagedFiles = try await SwiftLintTool.getGitDiffFilenames(cached: true, additionalArgs: ["../*.swift"])
                await SwiftLintTool.runSwiftLint(on: stagedFiles, withArgs: ["--config", "../.swiftlint.yml", "--force-exclude"], pathPrefix: "../", exitCodeManager: exitCodeManager)
                
                // Run for newly created unstaged files
                let newFiles = try await SwiftLintTool.getGitUntrackedFiles(additionalArgs: ["../*.swift"])
                await SwiftLintTool.runSwiftLint(on: newFiles, withArgs: ["--config", "../.swiftlint.yml", "--force-exclude"], pathPrefix: "../", exitCodeManager: exitCodeManager)
            } else {
                print("warning: SwiftLint not installed, download from https://github.com/realm/SwiftLint")
            }
            let code = await exitCodeManager.getExitCode()
            SwiftLintTool.exit(withError: code == 0 ? nil : ExitCode(code))
        }
    }
    
    // MARK: - Helper Functions
    
    static func runSwiftLint(on filenames: [String], withArgs args: [String], pathPrefix: String, exitCodeManager: ExitCodeManager) async {
        print("Running SwiftLint on \(filenames.count) files")
        await withTaskGroup(of: Void.self) { group in
            for filename in filenames {
                if shouldIgnore(filename: filename) {
                    print("Ignoring file: \(filename)")
                    continue
                }
                
                group.addTask {
                    // Analyze file
                    let fullPath = "\(pathPrefix)\(filename)"
                    let swiftlintArgs = args + [fullPath]
                    print("Running SwiftLint with args: \(swiftlintArgs)")
                    let exitStatus = await runSwiftLintProcess(with: swiftlintArgs)
                    
                    // Update exit code if error found
                    await exitCodeManager.update(exitCode: exitStatus)
                    print("SwiftLint finished for \(filename) with exit status: \(exitStatus)")
                }
            }
        }
        print("Finished running SwiftLint on all files")
    }
    
    static func shouldIgnore(filename: String) -> Bool {
        // Ignore autogenerated SwiftGen files and others
        return filename.contains("SwiftGen") ||
        filename.contains("Generated") ||
        filename.contains(".graphql")
    }
    
    static func runSwiftLintProcess(with arguments: [String]) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swiftlint"] + arguments
        
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        
        do {
            try await runProcessAsync(process)
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            print("Error running SwiftLint: \(error)")
            return 1
        }
    }
    
    static func isSwiftLintInstalled() async -> Bool {
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["swiftlint"]
        
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        
        do {
            try await runProcessAsync(whichProcess)
            whichProcess.waitUntilExit()
            return whichProcess.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    static func getGitDiffFilenames(cached: Bool, additionalArgs: [String] = []) async throws -> [String] {
        var args = ["diff", "--diff-filter=d", "--name-only", "--", "*.swift"]
        args += additionalArgs
        if cached {
            args.insert("--cached", at: 1)
        }
        return try await runGitCommand(args)
    }
    
    static func getGitUntrackedFiles(additionalArgs: [String] = []) async throws -> [String] {
        var args = ["ls-files", "--others", "--exclude-standard", "--full-name", "--", "*.swift"]
        args += additionalArgs
        return try await runGitCommand(args)
    }
    
    static func runGitCommand(_ arguments: [String]) async throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        try await runProcessAsync(process)
        process.waitUntilExit()
        
        let data = try await readDataAsync(from: pipe.fileHandleForReading)
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }
        return output.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }
    
    static func exportPath() {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { bufPtr -> String in
            let data = Data(bufPtr)
            if let lastIndex = data.firstIndex(where: { $0 == 0 }) {
                return String(data: data[..<lastIndex], encoding: .utf8) ?? ""
            } else {
                return String(data: data, encoding: .utf8) ?? ""
            }
        }
        
        if machine == "arm64" {
            if let path = ProcessInfo.processInfo.environment["PATH"] {
                let newPath = "/opt/homebrew/bin:\(path)"
                setenv("PATH", newPath, 1)
            }
        }
    }
    
    // MARK: - Asynchronous Process Running
    
    static func runProcessAsync(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    static func readDataAsync(from fileHandle: FileHandle) async throws -> Data {
        if #available(macOS 10.15.4, *) {
            return try fileHandle.readToEnd() ?? Data()
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    do {
                        let data = try fileHandle.readToEnd() ?? Data()
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
