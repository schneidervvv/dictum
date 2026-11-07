@MainActor
enum AppConstants {
    static let loggerSubsystem = "com.schneidervvv.dictum.termination-probe"
}

func record(_ event: String) {
    print(event)
    fflush(stdout)
}

@MainActor
final class TerminationRelaunchProbe: NSObject, NSApplicationDelegate {
    private let gate = PluginLocalInferenceGate()
    private lazy var preparation = TerminationPreparation(gate: gate)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        if CommandLine.arguments.contains("active") {
            let gate = gate
            _ = Task.detached {
                try await gate.withLock {
                    record("inference started")
                    RunLoop.main.perform(inModes: [.default]) {
                        completeApplicationRelaunch(.current, nil)
                    }
                    // 本地推理需要等当前分段完成，取消不会立即结束该分段。
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                            record("inference ended")
                            continuation.resume()
                        }
                    }
                }
            }
        } else {
            completeApplicationRelaunch(.current, nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        record("termination requested")
        return preparation.requestTermination {
            record("termination replied")
            sender.reply(toApplicationShouldTerminate: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        record("will terminate")
    }
}

let delegate = TerminationRelaunchProbe()
let application = NSApplication.shared
application.delegate = delegate
application.run()
