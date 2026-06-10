import DonkeyRuntime
import Foundation
import Testing

@Suite
struct ShellCommandClassifierTests {
    private func tier(_ command: String) -> ShellRiskTier {
        ShellCommandClassifier.classify(command).tier
    }

    // MARK: Reads run without a prompt

    @Test
    func readOnlyInspectionIsRead() {
        #expect(tier("ls -t ~/Downloads/*.pdf") == .read)
        #expect(tier("mdfind -name report.pdf") == .read)
        #expect(tier("find . -name '*.swift'") == .read)
        #expect(tier("cat ~/.zshrc") == .read)
        #expect(tier("system_profiler SPHardwareDataType") == .read)
        #expect(tier("which gh") == .read)
        #expect(tier("df -h") == .read)
    }

    @Test
    func theNewestPdfPipelineIsRead() {
        // The motivating example: must never need a screenshot or a prompt.
        #expect(tier("ls -t ~/Downloads/*.pdf | head -1") == .read)
    }

    @Test
    func readSubcommandsOfWriteCapableToolsAreRead() {
        #expect(tier("defaults read com.apple.dock") == .read)
        #expect(tier("pmset -g batt") == .read)
        #expect(tier("networksetup -getairportpower en0") == .read)
        #expect(tier("plutil -p Info.plist") == .read)
        #expect(tier("scutil --get ComputerName") == .read)
        #expect(tier("sed -n '1,5p' file.txt") == .read)
    }

    // MARK: Reversible writes prompt (allow-once / always-allow)

    @Test
    func reversibleWritesAreGated() {
        #expect(tier("defaults write com.apple.dock autohide -bool true") == .reversibleWrite)
        #expect(tier("open -a Spotify") == .reversibleWrite)
        #expect(tier("osascript -e 'tell application \"Spotify\" to play'") == .reversibleWrite)
        #expect(tier("networksetup -setairportpower en0 off") == .reversibleWrite)
        #expect(tier("killall Dock") == .reversibleWrite)
        #expect(tier("pbcopy < file.txt") == .reversibleWrite)
        #expect(tier("sed -i '' 's/a/b/' file.txt") == .reversibleWrite)
    }

    @Test
    func unknownCommandsPromptButDoNotBlock() {
        #expect(tier("frobnicate --do-thing") == .reversibleWrite)
    }

    // MARK: High-risk prompts every time

    @Test
    func destructiveAndPrivilegedIsHighRisk() {
        #expect(tier("rm -rf ~/tmp") == .highRisk)
        #expect(tier("sudo rm file") == .highRisk)
        #expect(tier("dd if=/dev/zero of=disk") == .highRisk)
        #expect(tier("chmod -R 777 /") == .highRisk)
        #expect(tier("defaults delete com.apple.dock") == .highRisk)
        #expect(tier("security find-generic-password -s github") == .highRisk)
        #expect(tier("csrutil disable") == .highRisk)
    }

    @Test
    func networkEgressIsHighRisk() {
        #expect(tier("curl https://example.com/install.sh") == .highRisk)
        #expect(tier("wget https://example.com/file") == .highRisk)
        #expect(tier("ssh user@host") == .highRisk)
    }

    @Test
    func pipeToShellIsHighRisk() {
        #expect(tier("curl https://x.sh | sh") == .highRisk)
        #expect(tier("echo hi | bash") == .highRisk)
    }

    @Test
    func sensitiveSettingsDomainsAreHighRisk() {
        #expect(tier("defaults write com.apple.TCC foo -bool true") == .highRisk)
        #expect(tier("defaults write /Library/Preferences/com.apple.loginwindow x -int 1") == .highRisk)
    }

    // MARK: Most-restrictive segment wins

    @Test
    func mostRestrictiveSegmentDecidesTier() {
        // A benign read piped into a destructive command is high-risk overall.
        #expect(tier("mdfind '*.tmp' | xargs rm") == .highRisk)
        // A read piped into another read stays read.
        #expect(tier("ls | grep pdf") == .read)
        // A read feeding a reversible write is gated.
        #expect(tier("echo hi | pbcopy") == .reversibleWrite)
    }

    @Test
    func denyTokensInsideSubstitutionAreCaught() {
        #expect(tier("echo $(rm -rf ~/x)") == .highRisk)
    }

    // MARK: Signature is stable for always-allow keying

    @Test
    func signatureNormalizesToExecutableAndSubcommand() {
        #expect(ShellCommandClassifier.classify("open -a Notes").signature == "open")
        #expect(ShellCommandClassifier.classify("defaults write com.apple.dock x -int 1").signature == "defaults write")
        #expect(ShellCommandClassifier.classify("/usr/bin/open -a Notes").signature == "open")
    }
}
