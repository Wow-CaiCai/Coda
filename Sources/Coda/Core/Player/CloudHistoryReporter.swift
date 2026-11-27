import Foundation
import os.log

/// Adds a single cloud history entry once the engine has played audible audio,
/// for the platforms whose own apps show recently played songs (Qishui, Bodian).
@MainActor
final class CloudHistoryReporter {
    private enum Target: Equatable {
        case qishui(trackID: String)
        case bodian(musicID: String)
    }

    private struct Session {
        let target: Target
        let ticket: UUID
        let credentials: [String: String]
        var listening = PlaybackListeningAccumulator()
        var submitted = false
    }

    private static let log = Logger(subsystem: "wow.caicai.coda", category: "cloud-history")
    private var active: Session?
    private var submission: Task<Void, Never>?

    func begin(_ track: Track) {
        let context = MusicProviderContext.shared
        guard active == nil else { return }
        switch context.current {
        case .qishui:
            let api = QishuiMusicAPI.shared
            guard api.isLoggedIn, let trackID = track.platformSong?.qishui?.trackID else { return }
            active = Session(target: .qishui(trackID: trackID), ticket: context.ticket, credentials: api.credentials)
        case .bodian:
            let api = BodianMusicAPI.shared
            guard api.isLoggedIn, let musicID = track.platformSong?.bodian?.musicID else { return }
            active = Session(target: .bodian(musicID: musicID), ticket: context.ticket, credentials: api.credentials)
        default:
            return
        }
    }

    func sample(position: TimeInterval, advancing: Bool) {
        guard var current = active, !current.submitted else { return }
        current.listening.sample(position: position, advancing: advancing, uptime: ProcessInfo.processInfo.systemUptime)
        if current.listening.seconds >= 0.25 {
            current.submitted = true
            submit(current)
        }
        active = current
    }

    func discontinuity() { active?.listening.discontinuity() }
    func finish() { active = nil }

    private func submit(_ current: Session) {
        let previous = submission
        submission = Task {
            await previous?.value
            do {
                try MusicProviderContext.shared.check(current.ticket)
                switch current.target {
                case .qishui(let trackID):
                    let api = QishuiMusicAPI.shared
                    guard api.credentials == current.credentials else { return }
                    try await api.appendRecentPlay(trackID: trackID)
                case .bodian(let musicID):
                    // Sent as the account that started the song, even if it changes meanwhile.
                    try await BodianMusicAPI.shared.appendRecentPlay(musicID: musicID, account: current.credentials)
                }
                try MusicProviderContext.shared.check(current.ticket)
                SidebarResources.playbackChanged()
            } catch is CancellationError {
                return
            } catch {
                Self.log.error("Recent play was not acknowledged")
            }
        }
    }
}
