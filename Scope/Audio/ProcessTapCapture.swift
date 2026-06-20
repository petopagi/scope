//
//  ProcessTapCapture.swift
//  Owns the Core Audio process tap + private aggregate device + IOProc for one
//  selected source, and pumps float samples into the ring buffer.
//
//  Lifecycle (verified against AudioHardwareTapping.h / AudioHardware.h):
//    CATapDescription → AudioHardwareCreateProcessTap → read kAudioTapPropertyFormat
//    → AudioHardwareCreateAggregateDevice (with the tap in its tap list, main
//      sub-device = default output) → AudioDeviceCreateIOProcIDWithBlock
//    → AudioDeviceStart.
//

import CoreAudio
import Foundation

final class ProcessTapCapture {

    let ring: AudioRingBuffer
    private(set) var sampleRate: Double = 48_000

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.scope.audio.io", qos: .userInteractive)

    private(set) var isRunning = false

    init(ring: AudioRingBuffer) {
        self.ring = ring
    }

    deinit { stop() }

    // MARK: Start / stop

    func start(source: AudioSource, muted: Bool) throws {
        stop()

        // 1. Describe the tap.
        let description: CATapDescription
        switch source.kind {
        case .systemWide:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case let .process(objectID, _):
            description = CATapDescription(stereoMixdownOfProcesses: [objectID])
        }
        description.uuid = UUID()
        description.name = "Scope Tap"
        // muted: capture the audio but silence its playback (the app makes no
        // sound). unmuted: pass the audio through so you still hear the source.
        description.muteBehavior = muted ? .mutedWhenTapped : .unmuted
        description.isPrivate = true               // don't pollute the global device list
        description.isMixdown = true

        // 2. Create the tap.
        var newTap: AudioObjectID = .unknown
        try caCheck(AudioHardwareCreateProcessTap(description, &newTap),
                    "AudioHardwareCreateProcessTap")
        tapID = newTap

        // 3. Ask the tap for its stream format (sample rate + channel count).
        let asbd = try tapID.read(kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000

        // 4. Build a private aggregate device whose main sub-device is the
        //    current default output, with our tap attached.
        let aggUID = UUID().uuidString
        let outputUID = (try? defaultOutputDeviceUID()) ?? ""
        let tapUID = description.uuid.uuidString

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scope Aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var newAggregate: AudioDeviceID = 0
        try caCheck(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate),
                    "AudioHardwareCreateAggregateDevice")
        aggregateID = newAggregate

        // 5. Install the real-time IO block. Capture only the ring + scalars —
        //    no `self`, no allocation, no locks, no ARC churn in here.
        let ring = self.ring
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let bufferCount = abl.count
            guard bufferCount > 0 else { return }

            let first = abl[0]
            if bufferCount >= 2,
               first.mNumberChannels == 1,
               abl[1].mNumberChannels == 1,
               let l = first.mData, let r = abl[1].mData {
                // Non-interleaved L / R.
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                ring.writePlanar(l.assumingMemoryBound(to: Float.self),
                                 r.assumingMemoryBound(to: Float.self),
                                 frames: frames)
            } else if let d = first.mData {
                let channels = Int(first.mNumberChannels)
                let base = d.assumingMemoryBound(to: Float.self)
                if channels >= 2 {
                    let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                    ring.writeInterleavedStereo(base, stride: channels, frames: frames)
                } else {
                    let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                    ring.writeMono(base, frames: frames)
                }
            }
        }

        var newProcID: AudioDeviceIOProcID?
        try caCheck(AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, ioQueue, ioBlock),
                    "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = newProcID

        // 6. Go.
        try caCheck(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        isRunning = true
    }

    func stop() {
        if let proc = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil

        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        isRunning = false
    }
}
