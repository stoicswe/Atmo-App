// Headless smoke test for the GLib ↔ Swift-concurrency bridge.
//
// Every AtmoCore call from the GTK app has the shape
// `Task { @MainActor in await service.something() }`. On Linux those
// MainActor jobs only run if something drains the dispatch main queue
// while GLib owns the main thread — that's MainLoopBridge's RunLoop pump.
//
// This binary reproduces the setup without a display: it parks the main
// thread in a GMainLoop (like g_application_run does), installs the same
// pump, and checks that a MainActor task — including an await that hops
// to a background actor and back — completes. Exit 0 = bridge works.
//
// Run it in the dev container:
//   swift run --scratch-path .build-linux AtmoSmoke

import Adwaita
import CAdw
import Foundation

nonisolated(unsafe) var mainLoop: OpaquePointer?
nonisolated(unsafe) var succeeded = false

actor BackgroundWorker {
    func double(_ value: Int) -> Int { value * 2 }
}

// The pump — identical to MainLoopBridge in the app: a 10 ms GLib
// timeout giving Foundation's RunLoop a zero-length pass, which drains
// the dispatch main queue (MainActor).
Idle(delay: 10) {
    RunLoop.main.run(until: Date())
    return true // keep the timeout source alive
}

// Safety timeout: if the MainActor task never runs, fail after 10 s.
Idle(delay: 10_000) {
    print("FAIL: MainActor task did not complete — bridge is broken")
    g_main_loop_quit(mainLoop)
    return false // G_SOURCE_REMOVE
}

// The workload under test, launched the way MainView.runCore launches
// AtmoCore work.
Task { @MainActor in
    let worker = BackgroundWorker()
    let result = await worker.double(21)   // suspend, hop off, resume on MainActor
    precondition(result == 42)
    succeeded = true
    print("OK: MainActor task ran under the GLib main loop (result: \(result))")
    g_main_loop_quit(mainLoop)
}

mainLoop = g_main_loop_new(nil, 0)
g_main_loop_run(mainLoop)
exit(succeeded ? 0 : 1)
