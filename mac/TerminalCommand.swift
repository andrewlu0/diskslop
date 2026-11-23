import AppKit

enum TerminalCommand {
    static let destination = URL(fileURLWithPath: "/usr/local/bin/diskslop")

    static func install() {
        let bundle = Bundle.main.bundleURL
        let source = bundle.appendingPathComponent("Contents/Helpers/diskslop")
        let manager = FileManager.default
        let candidates = [destination, URL(fileURLWithPath: "/opt/homebrew/bin/diskslop")]
        if let installed = candidates.first(where: {
            manager.isExecutableFile(atPath: $0.path) && $0.resolvingSymlinksInPath() == source.resolvingSymlinksInPath()
        }) {
            show("Terminal command is installed", installed.path)
            return
        }
        guard manager.isExecutableFile(atPath: source.path) else {
            show("Terminal command is missing", "Install a complete copy of DiskSlop and try again.")
            return
        }
        if (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true ||
            bundle.pathComponents.contains("AppTranslocation") {
            show("Move DiskSlop to Applications", "Open the installed app and choose Install Terminal Command again.")
            return
        }
        let path = destination.path
        if manager.fileExists(atPath: path) || (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
            show("A terminal command already exists", "The existing item at \(path) must be moved before DiskSlop can install its command.")
            return
        }
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.createSymbolicLink(at: destination, withDestinationURL: source)
            show("Terminal command installed", "Run diskslop --help in Terminal.")
        } catch {
            let failure = error as NSError
            guard failure.domain == NSCocoaErrorDomain && failure.code == NSFileWriteNoPermissionError else {
                show("Couldn’t install the terminal command", error.localizedDescription)
                return
            }
            installWithAuthorization(source)
        }
    }

    private static func installWithAuthorization(_ source: URL) {
        let script = """
        on run argv
            set target to "/usr/local/bin/diskslop"
            set installCommand to "/bin/mkdir -p /usr/local/bin && if [ -e " & target & " ] || [ -L " & target & " ]; then echo 'A command already exists at ' " & target & " >&2; exit 1; fi; /bin/ln -sh " & quoted form of (item 1 of argv) & " " & target
            try
                do shell script installCommand with administrator privileges
            on error number -128
                return "cancelled"
            end try
        end run
        """
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, source.path]
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 && message == "cancelled" { return }
                let succeeded = process.terminationStatus == 0
                DispatchQueue.main.async {
                    if succeeded { show("Terminal command installed", "Run diskslop --help in Terminal.") }
                    else { show("Couldn’t install the terminal command", message) }
                }
            } catch {
                DispatchQueue.main.async { show("Couldn’t install the terminal command", error.localizedDescription) }
            }
        }
    }

    private static func show(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
