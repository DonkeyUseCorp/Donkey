import DonkeyRuntime
import Foundation
import Testing

/// Proves the seatbelt jail actually confines a spawned process: writes land only in the workspace
/// folder, declared inputs are readable but other files are not, and the wrapper is a no-op without a
/// policy. The integration cases run a real `/bin/zsh` under `WorkspaceSandbox.wrap` and observe the
/// kernel's EPERM, so a regression in the profile fails loudly rather than silently widening the jail.
///
/// Test files live under `/private/tmp` (NOT the per-user darwin temp, which the profile deliberately
/// allows as scratch) so an out-of-jail write target is genuinely outside every allowed write root.
@Suite
struct WorkspaceSandboxTests {

    // MARK: - Profile shape (pure, no spawn)

    @Test
    func profileEncodesTheJailAndDeclaredInputs() {
        let policy = SandboxPolicy(writableRoots: ["/private/tmp"], readableRoots: ["/etc/hosts"], allowNetwork: true)
        let sbpl = WorkspaceSandbox.profile(for: policy, programPath: "/usr/bin:/bin", bundledToolsDir: nil)
        #expect(sbpl.contains("(deny default)"))
        #expect(sbpl.contains("(allow network*)"))
        #expect(sbpl.contains("(subpath \"/private/tmp\")"))   // the jail, writable
        #expect(sbpl.contains("(subpath \"/private/etc/hosts\")"))  // declared input, canonicalized for read
    }

    @Test
    func allowAllReadsOpensEveryRead() {
        // Shell commands set allowAllReads: the profile opens reads everywhere instead of locking them to
        // declared inputs, so the agent can inspect a file the user pointed it at.
        let policy = SandboxPolicy(writableRoots: ["/private/tmp"], allowAllReads: true)
        let sbpl = WorkspaceSandbox.profile(for: policy, programPath: "/usr/bin:/bin", bundledToolsDir: nil)
        #expect(sbpl.contains("(allow file-read* (subpath \"/\"))"))
    }

    @Test
    func profileAllowsSystemVIPCForSelfExtractingTools() {
        // A PyInstaller onefile binary (yt-dlp) relaunches itself through a System V semaphore; without
        // this rule its bootloader dies with `semctl: Operation not permitted` under (deny default), which
        // the agent misreads as a broken tool. Lock the allowance in so a profile edit can't silently drop
        // it and resurrect the pip/python consent loop.
        let policy = SandboxPolicy(writableRoots: ["/private/tmp"], allowAllReads: true)
        let sbpl = WorkspaceSandbox.profile(for: policy, programPath: "/usr/bin:/bin", bundledToolsDir: nil)
        #expect(sbpl.contains("(allow ipc-sysv-sem)"))
        #expect(sbpl.contains("(allow ipc-sysv-shm)"))
    }

    @Test
    func networkIsOmittedWhenDisallowed() {
        let policy = SandboxPolicy(writableRoots: ["/private/tmp"], readableRoots: [], allowNetwork: false)
        let sbpl = WorkspaceSandbox.profile(for: policy, programPath: "", bundledToolsDir: nil)
        #expect(!sbpl.contains("(allow network*)"))
    }

    @Test
    func wrapIsAPassthroughWithoutAPolicy() {
        let exe = URL(fileURLWithPath: "/bin/zsh")
        let (e1, a1) = WorkspaceSandbox.wrap(executable: exe, arguments: ["-c", "echo hi"], policy: nil,
                                             environment: [:], bundledToolsDir: nil)
        #expect(e1 == exe)
        #expect(a1 == ["-c", "echo hi"])
        // An empty policy is also inactive — nothing to contain.
        let empty = SandboxPolicy(writableRoots: [], readableRoots: [])
        #expect(WorkspaceSandbox.isActive(empty) == false)
        let (e2, _) = WorkspaceSandbox.wrap(executable: exe, arguments: [], policy: empty,
                                            environment: [:], bundledToolsDir: nil)
        #expect(e2 == exe)
    }

    @Test
    func wrapTargetsSandboxExec() {
        let policy = SandboxPolicy(writableRoots: ["/private/tmp"])
        let (exe, args) = WorkspaceSandbox.wrap(executable: URL(fileURLWithPath: "/bin/zsh"),
                                                arguments: ["-c", "echo hi"], policy: policy,
                                                environment: ["PATH": "/usr/bin:/bin"], bundledToolsDir: nil)
        #expect(exe.path == WorkspaceSandbox.sandboxExecPath)
        #expect(args.first == "-p")
        #expect(args.contains("/bin/zsh"))   // the real executable after the `--` separator
    }

    // MARK: - Kernel-enforced containment (real sandbox-exec)

    @Test
    func confinesWritesAndReadsToThePolicy() throws {
        try requireSandboxExec()
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let jail = base + "/jail"
        try FileManager.default.createDirectory(atPath: jail, withIntermediateDirectories: true)
        let input = base + "/input.txt"      // declared → readable
        let secret = base + "/secret.txt"    // NOT declared → unreadable
        let escape = base + "/escape.txt"    // outside jail → unwritable
        try "declared".write(toFile: input, atomically: true, encoding: .utf8)
        try "topsecret".write(toFile: secret, atomically: true, encoding: .utf8)

        let policy = SandboxPolicy(writableRoots: [jail], readableRoots: [input], allowNetwork: false)

        // Write inside the jail → allowed.
        #expect(runZsh(": > '\(jail)/out.txt'", policy: policy) == 0)
        #expect(FileManager.default.fileExists(atPath: jail + "/out.txt"))

        // Write outside the jail → blocked by the kernel; the file must not appear.
        #expect(runZsh(": > '\(escape)'", policy: policy) != 0)
        #expect(FileManager.default.fileExists(atPath: escape) == false)

        // Read the declared input → allowed; read a non-declared file → blocked.
        #expect(runZsh("cat '\(input)' > /dev/null", policy: policy) == 0)
        #expect(runZsh("cat '\(secret)' > /dev/null", policy: policy) != 0)
    }

    @Test
    func shellReadsAreOpenButWritesStayConfined() throws {
        try requireSandboxExec()
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let jail = base + "/jail"
        try FileManager.default.createDirectory(atPath: jail, withIntermediateDirectories: true)
        let secret = base + "/secret.txt"    // NOT declared, but shell reads are open
        let escape = base + "/escape.txt"    // outside jail → still unwritable
        try "topsecret".write(toFile: secret, atomically: true, encoding: .utf8)

        let policy = SandboxPolicy(writableRoots: [jail], allowNetwork: false, allowAllReads: true)

        // A non-declared file is readable (the consent classifier already treats reads as free)…
        #expect(runZsh("cat '\(secret)' > /dev/null", policy: policy) == 0)
        // …but a write outside the jail is still blocked by the kernel.
        #expect(runZsh(": > '\(escape)'", policy: policy) != 0)
        #expect(FileManager.default.fileExists(atPath: escape) == false)
    }

    @Test
    func systemVSemaphoreSucceedsInsideTheJail() throws {
        // The real failure that sent the agent into the pip/python consent loop: a System V semaphore op
        // (semget/semctl) denied by the seatbelt. Prove the kernel now permits it under the wrap by
        // compiling and running a tiny program that does exactly what yt-dlp's bootloader does. Skipped
        // cleanly if no C compiler is available.
        try requireSandboxExec()
        let cc = "/usr/bin/cc"
        try #require(FileManager.default.isExecutableFile(atPath: cc))

        let base = try makeBase()
        defer { try? FileManager.default.removeItem(atPath: base) }
        let source = base + "/sem.c"
        let binary = base + "/sem"
        try """
        #include <sys/sem.h>
        int main(void) {
            int id = semget(IPC_PRIVATE, 1, IPC_CREAT | 0600);   // what fails under a too-tight jail
            if (id < 0) return 1;
            semctl(id, 0, IPC_RMID);                              // the call that emitted "Operation not permitted"
            return 0;
        }
        """.write(toFile: source, atomically: true, encoding: .utf8)

        // Compile unsandboxed; only the run needs to be confined.
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: cc)
        compile.arguments = [source, "-o", binary]
        compile.standardOutput = FileHandle.nullDevice
        compile.standardError = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0)

        // Run it inside the jail — the kernel must allow the SysV semaphore calls.
        let policy = SandboxPolicy(writableRoots: [base], allowNetwork: false)
        let (exe, args) = WorkspaceSandbox.wrap(
            executable: URL(fileURLWithPath: binary),
            arguments: [],
            policy: policy,
            environment: ["PATH": "/usr/bin:/bin"],
            bundledToolsDir: nil
        )
        let run = Process()
        run.executableURL = exe
        run.arguments = args
        run.standardOutput = FileHandle.nullDevice
        run.standardError = FileHandle.nullDevice
        try run.run()
        run.waitUntilExit()
        #expect(run.terminationStatus == 0)
    }

    // MARK: - Helpers

    private func requireSandboxExec() throws {
        try #require(FileManager.default.isExecutableFile(atPath: WorkspaceSandbox.sandboxExecPath))
    }

    /// A canonical base dir under /private/tmp (world-writable, and NOT under the per-user darwin temp
    /// the profile allows), so an out-of-jail target is genuinely denied.
    private func makeBase() throws -> String {
        let base = "/private/tmp/donkey-sbx-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    /// Run a one-line script via `/bin/zsh` wrapped by the policy; return the exit code.
    private func runZsh(_ script: String, policy: SandboxPolicy?) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let (exe, args) = WorkspaceSandbox.wrap(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", script],
            policy: policy,
            environment: environment,
            bundledToolsDir: nil
        )
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
