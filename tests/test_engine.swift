import Foundation
import Darwin

@main struct EngineTests {
    @MainActor static func main() async {
        let engine = TranscriptionEngine()
        var results: [String] = [], failures: [String] = []
        let chunk = AudioChunk(id: "same", source: "microphone", start: 0, end: 1, path: "/unused")
        let first = TranscriptionJob(meetingID: "A", chunk: chunk, language: "", refinementID: "run1")
        let second = TranscriptionJob(meetingID: "B", chunk: chunk, language: "", refinementID: "run2")
        let live = TranscriptionJob(meetingID: "C", chunk: chunk, language: "")
        engine.onError = { failures.append($0) }
        engine.onJobStarted = { job in
            if job.identity == first.identity {
                engine.setRefinementsPaused(true)
                engine.enqueue([live, second]) // duplicate refinement must not duplicate work
            }
        }
        engine.onResult = { job, _, _ in results.append(job.identity) }
        engine.enqueue([first, second]); engine.start(); engine.start()
        for _ in 0..<500 {
            if results.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(failures.isEmpty, failures.joined(separator: "; "))
        precondition(results == [first.identity, live.identity], "Live audio did not preempt the refinement queue: \(results)")
        precondition(engine.pendingCount == 1, "Queued refinement lost or duplicated")
        engine.setRefinementsPaused(false)
        for _ in 0..<300 {
            if results.count == 3 && engine.pendingCount == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(results == [first.identity, live.identity, second.identity])

        let deleted = TranscriptionJob(meetingID: "deleted", chunk: chunk, language: "")
        let deletedRefinement = TranscriptionJob(meetingID: "deleted", chunk: chunk, language: "", refinementID: "deleted-run")
        let survivor = TranscriptionJob(meetingID: "survivor", chunk: chunk, language: "")
        engine.onJobStarted = { job in
            if job.meetingID == "deleted" {
                engine.cancelMeeting("deleted")
                engine.enqueue([deleted, deletedRefinement]) // late retries cannot revive it
            }
        }
        engine.enqueue([deleted, deletedRefinement, survivor])
        for _ in 0..<300 {
            if results.last == survivor.identity && engine.pendingCount == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(results == [first.identity, live.identity, second.identity, survivor.identity], "Deleted jobs returned or another meeting was cancelled")
        precondition(failures.isEmpty && engine.pendingCount == 0)
        let missing = AudioChunk(id: "missing", source: "system", start: 0, end: 1, path: "/force-error")
        let cancelledError = TranscriptionJob(meetingID: "deleted-error", chunk: missing, language: "")
        let survivor2 = TranscriptionJob(meetingID: "survivor2", chunk: chunk, language: "")
        engine.onJobStarted = { job in
            if job.meetingID == "deleted-error" { engine.cancelMeeting(job.meetingID) }
        }
        engine.enqueue([cancelledError, survivor2])
        for _ in 0..<300 {
            if results.last == survivor2.identity && engine.pendingCount == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(failures.isEmpty && results.last == survivor2.identity, "Late error from a deleted meeting leaked or blocked other work")

        let slowChunk = AudioChunk(id: "slow", source: "system", start: 0, end: 1, path: "/slow-ignore-term")
        let stopped = TranscriptionJob(meetingID: "stop-run", chunk: slowChunk, language: "", refinementID: "stop-id")
        let queued = TranscriptionJob(meetingID: "stop-run", chunk: chunk, language: "", refinementID: "stop-id")
        let sameMeetingLive = TranscriptionJob(meetingID: "stop-run", chunk: chunk, language: "")
        let otherPass = TranscriptionJob(meetingID: "other-pass", chunk: chunk, language: "", refinementID: "other-id")
        var started: [String] = [], fatalErrors: [String] = []
        engine.onJobStarted = { started.append($0.identity) }
        engine.onFatalError = { fatalErrors.append($0) }
        engine.enqueue([stopped, queued, otherPass])
        for _ in 0..<100 {
            if started.contains(stopped.identity) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(started.contains(stopped.identity))
        try? await Task.sleep(nanoseconds: 100_000_000) // Worker has entered its deliberately blocked inference.
        engine.enqueue([sameMeetingLive])
        engine.cancelRefinement(meetingID: "stop-run", runID: "stop-id", interruptActive: true)
        for _ in 0..<400 {
            if results.contains(otherPass.identity) && engine.pendingCount == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(!results.contains(stopped.identity) && !results.contains(queued.identity), "Stopped second-pass output leaked")
        precondition(Array(results.suffix(2)) == [sameMeetingLive.identity, otherPass.identity], "Cancellation lost original or unrelated transcription")
        precondition(failures.isEmpty && fatalErrors.isEmpty, "Intentional worker interruption was reported as failure")

        let rapid = TranscriptionJob(meetingID: "rapid", chunk: chunk, language: "", refinementID: "same-run")
        engine.enqueue([rapid])
        precondition(started.contains(rapid.identity))
        engine.cancelRefinement(meetingID: "rapid", runID: "same-run", interruptActive: true)
        engine.enqueue([rapid]); engine.start()
        for _ in 0..<300 {
            if results.contains(rapid.identity) && engine.pendingCount == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(results.filter { $0 == rapid.identity }.count == 1, "Immediate resume lost or duplicated the interrupted job")
        precondition(failures.isEmpty && fatalErrors.isEmpty)

        let qualityRoot = AppPaths.recordings.appendingPathComponent("quality-fixture")
        let qualityChunk = AudioChunk(id: "quality-success", source: "system", start: 0, end: 1, path: MeetingFiles.chunks(in: qualityRoot).appendingPathComponent("part.wav").path)
        let qualityBad = AudioChunk(id: "quality-failure", source: "system", start: 0, end: 1, path: qualityRoot.appendingPathComponent("system.wav").path)
        let recovered = TranscriptionJob(meetingID: "quality", chunk: qualityChunk, language: "")
        let rejected = TranscriptionJob(meetingID: "quality", chunk: qualityBad, language: "", refinementID: "run")
        var failedIDs: [String] = []
        engine.onJobFailure = { job, _ in failedIDs.append(job.identity) }
        engine.enqueue([recovered, rejected])
        for _ in 0..<300 {
            if failedIDs.contains(rejected.identity) && engine.pendingCount == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(results.contains(recovered.identity) && !results.contains(rejected.identity), "Quality failure was accepted as a transcript")
        let evidence = try! FileManager.default.contentsOfDirectory(at: MeetingFiles.working(in: qualityRoot).appendingPathComponent("quality"), includingPropertiesForKeys: nil)
        precondition(evidence.count == 2, "Recovered/failed raw attempts were not retained")
        precondition(failedIDs == [rejected.identity] && failures.count == 1)
        failures.removeAll()

        engine.unload()
        for _ in 0..<300 {
            if engine.state == "模型待命" && engine.memoryGB == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        precondition(!engine.ready && engine.memoryGB == 0, "Repeated start during loading caused an unwanted restart")
        engine.enqueue([rapid]); engine.start()
        engine.cancelRefinement(meetingID: "rapid", runID: "same-run", interruptActive: true)
        for _ in 0..<300 {
            if !engine.hasRunningProcess { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(!engine.hasRunningProcess && engine.pendingCount == 0 && failures.isEmpty, "Stop during model startup left work running")
        engine.terminate()
        print("PASS: real process protocol, live priority, active second-pass interruption, unrelated/live job survival, immediate resume, cancellation during startup, duplicate suppression, meeting cancellation, idle unload")
    }
}
