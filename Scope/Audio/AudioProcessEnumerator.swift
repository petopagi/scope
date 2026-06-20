//
//  AudioProcessEnumerator.swift
//  Lists audio-capable processes (resolved to app name + icon) plus a
//  "System (all audio)" option, for the source picker.
//

import AppKit
import CoreAudio
import Foundation

struct AudioSource: Identifiable, Hashable {
    enum Kind: Hashable {
        case systemWide
        case process(objectID: AudioObjectID, pid: pid_t)
    }

    let kind: Kind
    let name: String
    let bundleID: String?
    /// True if the process is currently producing output (helps the user pick).
    let isPlaying: Bool

    var id: String {
        switch kind {
        case .systemWide:                 return "system"
        case let .process(objectID, _):   return "proc-\(objectID)"
        }
    }

    var icon: NSImage? {
        switch kind {
        case .systemWide:
            return NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
        case let .process(_, pid):
            return NSRunningApplication(processIdentifier: pid)?.icon
        }
    }

    static let systemWide = AudioSource(kind: .systemWide,
                                        name: "System (all audio)",
                                        bundleID: nil,
                                        isPlaying: true)
}

enum AudioProcessEnumerator {

    /// "System (all audio)" first, then every resolvable running app that owns a
    /// Core Audio process object, with currently-playing apps sorted to the top.
    static func sources() -> [AudioSource] {
        var result: [AudioSource] = [.systemWide]

        let processObjects = (try? AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList, as: AudioObjectID.self)) ?? []

        let ownPID = ProcessInfo.processInfo.processIdentifier

        var apps: [AudioSource] = []
        for object in processObjects {
            guard let pid = try? object.read(kAudioProcessPropertyPID, as: pid_t.self),
                  pid > 0, pid != ownPID else { continue }
            guard let running = NSRunningApplication(processIdentifier: pid) else { continue }
            // Only surface real, user-facing apps (skip background audio daemons).
            guard running.activationPolicy == .regular else { continue }

            let name = running.localizedName
                ?? (try? object.readString(kAudioProcessPropertyBundleID))
                ?? "PID \(pid)"
            let bundleID = running.bundleIdentifier
                ?? (try? object.readString(kAudioProcessPropertyBundleID))
            let playing = (try? object.read(kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0

            apps.append(AudioSource(kind: .process(objectID: object, pid: pid),
                                    name: name,
                                    bundleID: bundleID,
                                    isPlaying: playing != 0))
        }

        // De-duplicate by bundle id (some apps register several helper processes),
        // preferring the one that is currently playing.
        var byKey: [String: AudioSource] = [:]
        for app in apps {
            let key = app.bundleID ?? app.id
            if let existing = byKey[key] {
                if app.isPlaying && !existing.isPlaying { byKey[key] = app }
            } else {
                byKey[key] = app
            }
        }

        let unique = byKey.values.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }   // playing first
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        result.append(contentsOf: unique)
        return result
    }
}
