import ArgumentParser
import Foundation

// Fan control keys, per AppleSMC:
//   FNum : UInt8   -- number of fans
//   F<n>Ac: fpe2   -- actual RPM
//   F<n>Mn: fpe2   -- min RPM
//   F<n>Mx: fpe2   -- max RPM
//   F<n>Tg: fpe2   -- target RPM (write to set)
//   F<n>Md: UInt8  -- mode: 0 = auto, 1 = forced (write to switch modes)
//
// Writes need root. macOS resumes thermal policy the instant F<n>Md returns to 0.

// Exit codes -- stable contract for callers.
//   0  success
//   1  runtime error (SMC I/O, bad key, unexpected size)
//   2  needs root
//   64 usage error (argument parsing)

struct FanInfo: Encodable {
    let index: Int
    let mode: String        // "auto" | "forced"
    let actual_rpm: Int
    let target_rpm: Int
    let min_rpm: Int
    let max_rpm: Int
}

struct StatusOutput: Encodable {
    let fans: [FanInfo]
}

struct ActionResult: Encodable {
    let fan: Int
    let mode: String
    let target_rpm: Int
    let min_rpm: Int
    let max_rpm: Int
}

struct ActionOutput: Encodable {
    let action: String
    let results: [ActionResult]
}

struct ErrorOutput: Encodable {
    let error: String
    let detail: String?
}

func jsonEncode<T: Encodable>(_ value: T) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let data = (try? enc.encode(value)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
}

func emitError(_ message: String, detail: String? = nil, json: Bool) {
    let text: String
    if json {
        text = jsonEncode(ErrorOutput(error: message, detail: detail)) + "\n"
    } else {
        text = detail.map { "fancontrol: \(message): \($0)\n" } ?? "fancontrol: \(message)\n"
    }
    FileHandle.standardError.write(Data(text.utf8))
}

func readFans(_ smc: SMC) throws -> [FanInfo] {
    let count = try smc.readUInt8("FNum")
    var out: [FanInfo] = []
    for i in 0..<Int(count) {
        let a = try smc.readFPE2("F\(i)Ac")
        let mn = try smc.readFPE2("F\(i)Mn")
        let mx = try smc.readFPE2("F\(i)Mx")
        let tg = try smc.readFPE2("F\(i)Tg")
        let md = (try? smc.readUInt8("F\(i)Md")) ?? 0
        out.append(FanInfo(
            index: i,
            mode: md == 1 ? "forced" : "auto",
            actual_rpm: Int(a.rounded()),
            target_rpm: Int(tg.rounded()),
            min_rpm: Int(mn.rounded()),
            max_rpm: Int(mx.rounded())
        ))
    }
    return out
}

func openSMC(json: Bool) throws -> SMC {
    do { return try SMC() }
    catch { emitError("SMC open failed", detail: "\(error)", json: json); throw ExitCode(1) }
}

func requireRoot(json: Bool) throws {
    if getuid() != 0 {
        emitError("this action needs root; re-run under sudo", json: json)
        throw ExitCode(2)
    }
}

@main
struct FanControl: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fancontrol",
        abstract: "Read and override Mac fan speeds via AppleSMC. Designed for agents and scripts.",
        discussion: """
Exit codes: 0 ok, 1 runtime error, 2 needs root, 64 usage error.
Every subcommand accepts --json for structured output on stdout;
errors are emitted as JSON on stderr when --json is set.
""",
        version: "0.1.0",
        subcommands: [Status.self, Max.self, Auto.self, Set.self],
        defaultSubcommand: Status.self
    )
}

extension FanControl {

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print fan RPMs and mode.")
        @Flag(help: "Emit JSON on stdout.") var json = false

        func run() throws {
            let smc = try openSMC(json: json)
            let fans: [FanInfo]
            do { fans = try readFans(smc) }
            catch { if case SMCError.notPrivileged = error { emitError("SMC access denied; re-run under sudo", json: json); throw ExitCode(2) }; emitError("SMC read failed", detail: "\(error)", json: json); throw ExitCode(1) }

            if json {
                print(jsonEncode(StatusOutput(fans: fans)))
            } else {
                print(String(format: "%-4s %-6s %-7s %-7s %-6s %-6s",
                             "fan", "mode", "actual", "target", "min", "max"))
                for f in fans {
                    print(String(format: "%-4d %-6s %7d %7d %6d %6d",
                                 f.index, f.mode, f.actual_rpm, f.target_rpm,
                                 f.min_rpm, f.max_rpm))
                }
            }
        }
    }

    struct Max: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Force every fan to its maximum RPM. Needs sudo.")
        @Flag(help: "Emit JSON on stdout.") var json = false

        func run() throws {
            try requireRoot(json: json)
            let smc = try openSMC(json: json)
            let fans = try readFans(smc)
            var results: [ActionResult] = []
            for f in fans {
                do {
                    try smc.write("F\(f.index)Md", bytes: [1])
                    try smc.writeFPE2("F\(f.index)Tg", Double(f.max_rpm))
                } catch {
                    emitError("write failed on fan \(f.index)", detail: "\(error)", json: json)
                    throw ExitCode(1)
                }
                results.append(ActionResult(
                    fan: f.index, mode: "forced",
                    target_rpm: f.max_rpm, min_rpm: f.min_rpm, max_rpm: f.max_rpm))
            }
            emit(action: "max", results: results, json: json)
        }
    }

    struct Auto: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Return every fan to macOS thermal control. Needs sudo.")
        @Flag(help: "Emit JSON on stdout.") var json = false

        func run() throws {
            try requireRoot(json: json)
            let smc = try openSMC(json: json)
            let fans = try readFans(smc)
            var results: [ActionResult] = []
            for f in fans {
                do { try smc.write("F\(f.index)Md", bytes: [0]) }
                catch {
                    emitError("write failed on fan \(f.index)", detail: "\(error)", json: json)
                    throw ExitCode(1)
                }
                results.append(ActionResult(
                    fan: f.index, mode: "auto",
                    target_rpm: f.target_rpm, min_rpm: f.min_rpm, max_rpm: f.max_rpm))
            }
            emit(action: "auto", results: results, json: json)
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Force a target RPM on one or every fan. Needs sudo.")
        @Argument(help: "Target RPM. Clamped to the fan's min/max.") var rpm: Double
        @Option(name: .shortAndLong, help: "Fan index; omit to set every fan.")
        var fan: Int?
        @Flag(help: "Emit JSON on stdout.") var json = false

        func run() throws {
            try requireRoot(json: json)
            let smc = try openSMC(json: json)
            let fans = try readFans(smc)
            let targets: [FanInfo]
            if let f = fan {
                guard f >= 0 && f < fans.count else {
                    emitError("fan index \(f) out of range 0..<\(fans.count)", json: json)
                    throw ExitCode(1)
                }
                targets = [fans[f]]
            } else {
                targets = fans
            }
            var results: [ActionResult] = []
            for f in targets {
                let clamped = Int(min(max(rpm, Double(f.min_rpm)), Double(f.max_rpm)))
                do {
                    try smc.write("F\(f.index)Md", bytes: [1])
                    try smc.writeFPE2("F\(f.index)Tg", Double(clamped))
                } catch {
                    emitError("write failed on fan \(f.index)", detail: "\(error)", json: json)
                    throw ExitCode(1)
                }
                results.append(ActionResult(
                    fan: f.index, mode: "forced",
                    target_rpm: clamped, min_rpm: f.min_rpm, max_rpm: f.max_rpm))
            }
            emit(action: "set", results: results, json: json)
        }
    }
}

private func emit(action: String, results: [ActionResult], json: Bool) {
    if json {
        print(jsonEncode(ActionOutput(action: action, results: results)))
    } else {
        for r in results {
            print("fan \(r.fan): mode=\(r.mode) target=\(r.target_rpm) rpm")
        }
    }
}
