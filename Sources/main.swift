// OpenPlaySync — play system audio on any set of output devices at once,
// with a per-device delay (to line up Bluetooth latency) and per-device volume.
//
// How it works:
//   1. A Core Audio process tap captures all system audio (excluding this app)
//      and mutes the original output, so nothing plays twice.
//   2. A private aggregate device is built live from the devices you tick.
//   3. One IO callback writes the tapped audio into a ring buffer and reads it
//      back for each device at that device's own delay and gain.

import SwiftUI
import CoreAudio
import AudioToolbox

// MARK: - Core Audio helpers

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
}

func stringProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value else { return "" }
    return v.takeRetainedValue() as String
}

func uint32Prop(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(sel)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
    return v
}

func allDeviceIDs() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids)
    return ids
}

/// Channel count of each output stream of a device, in stream order.
func outputStreamChannels(_ id: AudioDeviceID) -> [Int] {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return [] }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.map { Int($0.mNumberChannels) }
}

func deviceID(forUID uid: String) -> AudioDeviceID? {
    var a = addr(kAudioHardwarePropertyTranslateUIDToDevice)
    var cfUID = uid as CFString
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let err = withUnsafeMutablePointer(to: &cfUID) { p in
        AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<CFString>.size), p, &size, &id)
    }
    return (err == noErr && id != kAudioObjectUnknown) ? id : nil
}

func ownProcessObject() -> AudioObjectID {
    var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = getpid()
    var obj = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
    return obj
}

func nominalSampleRate(_ id: AudioObjectID) -> Double {
    var a = addr(kAudioDevicePropertyNominalSampleRate)
    var sr = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &sr)
    return sr > 0 ? sr : 48000
}

func transportLabel(_ t: UInt32) -> String {
    switch t {
    case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    default: return "Other"
    }
}

// Hardware output volume (0...1): main element if present, else channels 1 & 2.
func volumeElements(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
    var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
    var settable: DarwinBoolean = false
    if AudioObjectHasProperty(id, &a),
       AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue {
        return [kAudioObjectPropertyElementMain]
    }
    return [1, 2].filter { el in
        a.mElement = el
        return AudioObjectHasProperty(id, &a)
            && AudioObjectIsPropertySettable(id, &a, &settable) == noErr && settable.boolValue
    }
}

func getHardwareVolume(_ id: AudioDeviceID) -> Float? {
    guard let el = volumeElements(id).first else { return nil }
    var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
    var v = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func isMuted(_ id: AudioDeviceID) -> Bool {
    var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
    guard AudioObjectHasProperty(id, &a) else { return false }
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
    return v != 0
}

func defaultOutputDevice() -> AudioDeviceID {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &id)
    return id
}

func setHardwareVolume(_ id: AudioDeviceID, _ value: Float) {
    var v = Float32(min(max(value, 0), 1))
    for el in volumeElements(id) {
        var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
        AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}

// MARK: - Real-time state (preallocated, touched by the IO thread)

final class RTState {
    static let maxDevices = 16
    static let maxBuffers = 64
    let capacity = 384_000            // ring size: 4 s at 96 kHz
    let ringL: UnsafeMutablePointer<Float>
    let ringR: UnsafeMutablePointer<Float>
    var write = 0
    var sampleRate = 48000.0

    // Per device
    let delay = UnsafeMutablePointer<Int>.allocate(capacity: maxDevices)
    let gain = UnsafeMutablePointer<Float>.allocate(capacity: maxDevices)
    let devChannels = UnsafeMutablePointer<Int>.allocate(capacity: maxDevices)
    // Per output buffer of the aggregate
    var bufferCount = 0
    let bufDevice = UnsafeMutablePointer<Int>.allocate(capacity: maxBuffers)
    let bufChanOffset = UnsafeMutablePointer<Int>.allocate(capacity: maxBuffers)

    // Test clicks
    var clicksLeft = 0
    var clickTimer = 0

    init() {
        ringL = .allocate(capacity: capacity); ringL.initialize(repeating: 0, count: capacity)
        ringR = .allocate(capacity: capacity); ringR.initialize(repeating: 0, count: capacity)
        delay.initialize(repeating: 0, count: RTState.maxDevices)
        gain.initialize(repeating: 1, count: RTState.maxDevices)
        devChannels.initialize(repeating: 2, count: RTState.maxDevices)
        bufDevice.initialize(repeating: -1, count: RTState.maxBuffers)
        bufChanOffset.initialize(repeating: 0, count: RTState.maxBuffers)
    }

    func reset() {
        ringL.update(repeating: 0, count: capacity)
        ringR.update(repeating: 0, count: capacity)
        write = 0
        clicksLeft = 0
    }

    func process(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer) {
        // The tap is the last input stream(s); take the last two input channels as L/R.
        let totalIn = input.reduce(0) { $0 + Int($1.mNumberChannels) }
        let frames: Int = {
            if let b = output.first, b.mNumberChannels > 0 {
                return Int(b.mDataByteSize) / (4 * Int(b.mNumberChannels))
            }
            return 0
        }()
        guard frames > 0 else { return }

        let w0 = write
        let clickLen = Int(sampleRate * 0.03)
        let clickInterval = Int(sampleRate * 0.6)
        for f in 0..<frames {
            var l: Float = 0, r: Float = 0
            if totalIn >= 2 {
                l = inSample(input, channel: totalIn - 2, frame: f)
                r = inSample(input, channel: totalIn - 1, frame: f)
            } else if totalIn == 1 {
                l = inSample(input, channel: 0, frame: f); r = l
            }
            if clicksLeft > 0 {
                if clickTimer < clickLen {
                    let t = Float(clickTimer) / Float(sampleRate)
                    let s = sinf(2 * .pi * 1500 * t) * expf(-t / 0.006) * 0.7
                    l += s; r += s
                }
                clickTimer += 1
                if clickTimer >= clickInterval { clickTimer = 0; clicksLeft -= 1 }
            }
            let idx = (w0 + f) % capacity
            ringL[idx] = l
            ringR[idx] = r
        }
        write = (w0 + frames) % capacity

        for b in 0..<min(output.count, bufferCount) {
            let buf = output[b]
            guard let data = buf.mData else { continue }
            let p = data.assumingMemoryBound(to: Float.self)
            let n = Int(buf.mNumberChannels)
            let bufFrames = n > 0 ? Int(buf.mDataByteSize) / (4 * n) : 0
            let dev = bufDevice[b]
            if dev < 0 { p.update(repeating: 0, count: bufFrames * n); continue }
            let d = min(max(delay[dev], 0), capacity - frames - 1)
            let g = gain[dev]
            let mono = devChannels[dev] == 1
            let off = bufChanOffset[b]
            for f in 0..<bufFrames {
                let idx = (w0 + f - d + capacity) % capacity
                let l = ringL[idx], r = ringR[idx]
                for k in 0..<n {
                    let s: Float = mono ? (l + r) * 0.5 : ((off + k) % 2 == 0 ? l : r)
                    p[f * n + k] = s * g
                }
            }
        }
    }

    @inline(__always)
    private func inSample(_ abl: UnsafeMutableAudioBufferListPointer, channel: Int, frame: Int) -> Float {
        var c = channel
        for buf in abl {
            let n = Int(buf.mNumberChannels)
            if c < n {
                guard let d = buf.mData else { return 0 }
                let frames = Int(buf.mDataByteSize) / (4 * n)
                return frame < frames ? d.assumingMemoryBound(to: Float.self)[frame * n + c] : 0
            }
            c -= n
        }
        return 0
    }
}

// MARK: - Model

struct OutputDevice: Identifiable, Equatable {
    let uid: String
    let audioID: AudioDeviceID
    let name: String
    let transport: String
    let hasHardwareVolume: Bool
    let canPlay: Bool          // has output channels
    let isAggregate: Bool      // aggregate / multi-output device
    var id: String { uid }
}

@MainActor
final class Engine: ObservableObject {
    @Published var devices: [OutputDevice] = []
    @Published var selected: Set<String> { didSet { save(); restartIfRunning() } }
    @Published var delays: [String: Double] { didSet { save(); applyDelaysAndGains() } }
    @Published var volumes: [String: Double] = [:]
    @Published var softGains: [String: Double] { didSet { save(); applyDelaysAndGains() } }
    @Published var running = false
    @Published var status = "Stopped"
    /// The Mac's current sound output (what the volume keys control).
    @Published var masterName = ""
    @Published var masterVolume: Double = 1
    @Published var masterMuted = false
    private var masterID = AudioDeviceID(kAudioObjectUnknown)
    private var masterUID = ""
    private var masterListeners: [(AudioDeviceID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let rt = RTState()
    /// UID -> index in the RT per-device arrays for the running aggregate.
    private var activeIndex: [String: Int] = [:]
    private var listener: AudioObjectPropertyListenerBlock?
    private let defaults = UserDefaults.standard
    static weak var shared: Engine?

    init() {
        selected = Set(defaults.stringArray(forKey: "selected") ?? [])
        delays = (defaults.dictionary(forKey: "delays") as? [String: Double]) ?? [:]
        softGains = (defaults.dictionary(forKey: "softGains") as? [String: Double]) ?? [:]

        refreshDevices()

        // First run: built-in speakers + any Bluetooth speakers, with the built-in
        // ones delayed by a typical Bluetooth latency.
        if defaults.stringArray(forKey: "selected") == nil {
            let outs = devices.filter { $0.canPlay && !$0.isAggregate }
            let builtIn = outs.filter { $0.transport == "Built-in" }
            let bluetooth = outs.filter { $0.transport == "Bluetooth" }
            selected = Set((builtIn + bluetooth).map(\.uid))
            if !bluetooth.isEmpty { for d in builtIn { delays[d.uid] = 200 } }
        }

        watchDeviceList()
        watchMaster()
        start()
        Engine.shared = self
    }

    // MARK: Master volume (follows the Mac's volume keys)

    /// Track the default output device and its volume/mute. Because the tap mutes
    /// normal playback, the volume keys would otherwise do nothing; instead their
    /// value scales every device OpenPlaySync plays to.
    private func watchMaster() {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(systemObject, &a, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in self?.attachToDefaultOutput() }
        }
        attachToDefaultOutput()
    }

    private func attachToDefaultOutput() {
        for (id, address, block) in masterListeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(id, &a, DispatchQueue.main, block)
        }
        masterListeners = []

        masterID = defaultOutputDevice()
        masterName = stringProp(masterID, kAudioObjectPropertyName)
        // Multi-output / aggregate devices have no volume control, which disables the
        // volume keys. Switch the Mac's output to a real device that has one.
        if volumeElements(masterID).isEmpty,
           let better = devices.first(where: { selected.contains($0.uid) && $0.hasHardwareVolume && !$0.isAggregate })
                ?? devices.first(where: { $0.hasHardwareVolume && !$0.isAggregate }) {
            var id = better.audioID
            for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
                var a = addr(sel)
                AudioObjectSetPropertyData(systemObject, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
            }
            return   // the default-device listener calls back in with the new device
        }
        masterUID = stringProp(masterID, kAudioDevicePropertyDeviceUID)
        masterName = stringProp(masterID, kAudioObjectPropertyName)

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.readMaster() }
        }
        var addresses = volumeElements(masterID).map {
            addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, $0)
        }
        addresses.append(addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput))
        for var a in addresses where AudioObjectHasProperty(masterID, &a) {
            AudioObjectAddPropertyListenerBlock(masterID, &a, DispatchQueue.main, block)
            masterListeners.append((masterID, a, block))
        }
        readMaster()
    }

    private func readMaster() {
        masterVolume = Double(getHardwareVolume(masterID) ?? 1)
        masterMuted = isMuted(masterID)
        refreshVolumes()            // the default device's own slider moves with the keys
        applyDelaysAndGains()
    }

    // MARK: Persistence

    private func save() {
        defaults.set(Array(selected), forKey: "selected")
        defaults.set(delays, forKey: "delays")
        defaults.set(softGains, forKey: "softGains")
    }

    // MARK: Device list

    func refreshDevices() {
        let rank: (OutputDevice) -> Int = { d in
            if !d.canPlay { return 3 }
            if d.isAggregate { return 2 }
            return d.transport == "Built-in" ? 0 : 1
        }
        devices = allDeviceIDs().compactMap { id in
            let uid = stringProp(id, kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty, !uid.hasPrefix("com.couralabs.openplaysync.") else { return nil }
            let transport = uint32Prop(id, kAudioDevicePropertyTransportType)
            let canPlay = !outputStreamChannels(id).isEmpty
            let isAggregate = transport == kAudioDeviceTransportTypeAggregate
            return OutputDevice(uid: uid, audioID: id, name: stringProp(id, kAudioObjectPropertyName),
                                transport: isAggregate ? "Aggregate" : transportLabel(transport),
                                hasHardwareVolume: canPlay && !volumeElements(id).isEmpty,
                                canPlay: canPlay, isAggregate: isAggregate)
        }
        .sorted { (rank($0), $0.name.lowercased()) < (rank($1), $1.name.lowercased()) }
        refreshVolumes()
    }

    func refreshVolumes() {
        for d in devices where d.hasHardwareVolume {
            if let v = getHardwareVolume(d.audioID) { volumes[d.uid] = Double(v) }
        }
    }

    private func watchDeviceList() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let before = Set(self.devices.map(\.uid))
                self.refreshDevices()
                let after = Set(self.devices.map(\.uid))
                // A selected device appeared or vanished: rebuild the aggregate.
                if self.running, !before.symmetricDifference(after).intersection(self.selected).isEmpty {
                    self.restartIfRunning()
                }
            }
        }
        listener = block
        var a = addr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObject, &a, DispatchQueue.main, block)
    }

    // MARK: Per-device controls

    func isSelected(_ uid: String) -> Bool { selected.contains(uid) }
    var selectedCount: Int { devices.filter { $0.canPlay && selected.contains($0.uid) }.count }
    func setSelected(_ uid: String, _ on: Bool) {
        if on { selected.insert(uid) } else { selected.remove(uid) }
    }

    func delay(_ uid: String) -> Double { delays[uid] ?? 0 }
    func setDelay(_ uid: String, _ ms: Double) { delays[uid] = min(max(ms, 0), 1000).rounded() }

    func volume(_ d: OutputDevice) -> Double {
        d.hasHardwareVolume ? (volumes[d.uid] ?? 1) : (softGains[d.uid] ?? 1)
    }
    func setVolume(_ d: OutputDevice, _ v: Double) {
        if d.hasHardwareVolume {
            volumes[d.uid] = v
            setHardwareVolume(d.audioID, Float(v))
        } else {
            softGains[d.uid] = v
        }
    }

    func playTestClicks() {
        rt.clickTimer = 0
        rt.clicksLeft = 6
    }

    private func applyDelaysAndGains() {
        let master: Float = masterMuted ? 0 : Float(masterVolume)
        for (uid, i) in activeIndex {
            rt.delay[i] = Int(delay(uid) / 1000 * rt.sampleRate)
            let hw = devices.first { $0.uid == uid }?.hasHardwareVolume ?? true
            let own: Float = hw ? 1 : Float(softGains[uid] ?? 1)
            // If this device IS the Mac's output, the keys already change its
            // hardware volume — don't apply the master on top (except mute).
            let follow: Float = uid == masterUID ? (masterMuted ? 0 : 1) : master
            rt.gain[i] = own * follow
        }
    }

    // MARK: Start / stop

    /// False only after the user pressed Stop; ticking devices then won't auto-start.
    private var wantsRunning = true

    func toggle() {
        wantsRunning = !running
        running ? stop() : start()
    }

    private func restartIfRunning() {
        guard wantsRunning else { return }
        stop()
        start()
    }

    func start() {
        guard procID == nil else { return }
        // Selected devices that are connected right now, built-in first (most stable clock).
        let chosen = devices.filter { selected.contains($0.uid) && $0.canPlay }
        guard !chosen.isEmpty else { status = "Tick at least one device"; running = false; return }
        guard chosen.count <= RTState.maxDevices else { status = "Too many devices"; return }

        // 1. Tap all system audio except our own, muting the original output.
        let me = ownProcessObject()
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: me == kAudioObjectUnknown ? [] : [me])
        tapDesc.uuid = UUID()
        tapDesc.muteBehavior = .mutedWhenTapped
        tapDesc.isPrivate = true
        tapDesc.name = "OpenPlaySync Tap"
        var err = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard err == noErr else { status = "Tap failed (\(err)) — allow audio capture?"; teardown(); return }

        // 2. Private aggregate of the chosen devices + the tap.
        let clockUID = chosen[0].uid
        let subDevices: [[String: Any]] = chosen.map {
            [kAudioSubDeviceUIDKey: $0.uid, kAudioSubDeviceDriftCompensationKey: $0.uid != clockUID]
        }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenPlaySync",
            kAudioAggregateDeviceUIDKey: "com.couralabs.openplaysync.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceClockDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard err == noErr else { status = "Aggregate failed (\(err))"; teardown(); return }

        // 3. Map aggregate output buffers -> device, in the order the aggregate reports.
        let order = activeSubDeviceUIDs(aggID)
        activeIndex = [:]
        var b = 0
        for (i, uid) in order.enumerated() {
            guard let id = deviceID(forUID: uid) else { continue }
            let streams = outputStreamChannels(id)
            activeIndex[uid] = i
            rt.devChannels[i] = streams.reduce(0, +)
            var chanOffset = 0
            for ch in streams where b < RTState.maxBuffers {
                rt.bufDevice[b] = i
                rt.bufChanOffset[b] = chanOffset
                chanOffset += ch
                b += 1
            }
        }
        rt.bufferCount = b
        rt.sampleRate = nominalSampleRate(aggID)
        rt.reset()
        applyDelaysAndGains()

        // 4. Run.
        let rt = self.rt
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
            rt.process(input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)),
                       output: UnsafeMutableAudioBufferListPointer(outData))
        }
        guard err == noErr, let procID else { status = "IOProc failed (\(err))"; teardown(); return }
        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else { status = "Start failed (\(err))"; teardown(); return }

        running = true
        let missing = selected.count - chosen.count
        status = "Playing on \(chosen.count) device\(chosen.count == 1 ? "" : "s") · \(Int(rt.sampleRate)) Hz"
            + (missing > 0 ? " · \(missing) offline" : "")
    }

    private func activeSubDeviceUIDs(_ agg: AudioObjectID) -> [String] {
        var a = addr(kAudioAggregateDevicePropertyActiveSubDeviceList)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(agg, &a, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(agg, &a, 0, nil, &size, &ids)
        return ids.map { stringProp($0, kAudioDevicePropertyDeviceUID) }
    }

    func stop() {
        teardown()
        running = false
        status = "Stopped"
    }

    private func teardown() {
        if let procID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID) }
        aggID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        activeIndex = [:]
    }
}

// MARK: - UI

struct DeviceRow: View {
    @ObservedObject var engine: Engine
    let device: OutputDevice

    var body: some View {
        let on = engine.isSelected(device.uid) && device.canPlay
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { on }, set: { engine.setSelected(device.uid, $0) })) {
                HStack(spacing: 6) {
                    Image(systemName: icon).frame(width: 16)
                    Text(device.name).lineLimit(1)
                    Spacer()
                    Text(device.canPlay ? device.transport : "Input only")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!device.canPlay)
            .opacity(device.canPlay ? 1 : 0.5)
            .help(device.canPlay ? "Play system audio on this device" : "This device has no outputs, so it can't play audio")

            if on {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill").font(.caption).frame(width: 16)
                        Slider(value: Binding(get: { engine.volume(device) },
                                              set: { engine.setVolume(device, $0) }), in: 0...1)
                        Text("\(Int(engine.volume(device) * 100))%")
                            .monospacedDigit().font(.caption).frame(width: 38, alignment: .trailing)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "timer").font(.caption).frame(width: 16)
                        Slider(value: Binding(get: { engine.delay(device.uid) },
                                              set: { engine.setDelay(device.uid, $0) }), in: 0...600)
                        Text("\(Int(engine.delay(device.uid))) ms")
                            .monospacedDigit().font(.caption).frame(width: 52, alignment: .trailing)
                    }
                    HStack(spacing: 4) {
                        Spacer().frame(width: 16)
                        ForEach([-10, -1, 1, 10], id: \.self) { step in
                            Button(step > 0 ? "+\(step)" : "−\(-step)") {
                                engine.setDelay(device.uid, engine.delay(device.uid) + Double(step))
                            }
                            .controlSize(.small)
                        }
                        Spacer()
                        Button("0") { engine.setDelay(device.uid, 0) }.controlSize(.small)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
    }

    var icon: String {
        if !device.canPlay { return "mic" }
        switch device.transport {
        case "Aggregate": return "square.stack.3d.up"
        case "Built-in": return "laptopcomputer"
        case "Bluetooth": return "hifispeaker"
        case "HDMI", "DisplayPort", "Thunderbolt": return "display"
        case "AirPlay": return "airplayaudio"
        case "USB": return "cable.connector"
        default: return "speaker"
        }
    }
}

@main
struct OpenPlaySyncApp: App {
    @StateObject private var engine = Engine()

    init() {
        // Debug: `OpenPlaySync --snapshot <file.png>` renders the menu to an image and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    let renderer = ImageRenderer(content: MenuContent(engine: Engine.shared!)
                        .background(Color(nsColor: .windowBackgroundColor)))
                    renderer.scale = 2
                    if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path))
                    }
                    Engine.shared?.stop()
                    exit(0)
                }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("Open Play Sync", systemImage: engine.running ? "hifispeaker.2.fill" : "hifispeaker.2") {
            MenuContent(engine: engine)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    @ObservedObject var engine: Engine

    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Open Play Sync").font(.headline)
                    Spacer()
                    Button(engine.running ? "Stop" : "Start") { engine.toggle() }
                }
                Text(engine.status).font(.caption).foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label("Master (volume keys)", systemImage: engine.masterMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        Spacer()
                        Text(engine.masterMuted ? "Muted" : "\(Int(engine.masterVolume * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: engine.masterMuted ? 0 : engine.masterVolume)
                    Text("Follows \(engine.masterName). Use the keyboard volume keys or menu bar.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("Sound devices").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(engine.selectedCount) syncing").font(.caption).foregroundStyle(.secondary)
                }
                // Plain stack: a ScrollView inside a MenuBarExtra window collapses to zero height.
                VStack(alignment: .leading, spacing: 0) {
                    if engine.devices.isEmpty {
                        Text("No sound devices found").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(engine.devices) { d in
                        DeviceRow(engine: engine, device: d)
                        if d.id != engine.devices.last?.id { Divider() }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Button("Play test clicks") { engine.playTestClicks() }
                        .disabled(!engine.running)
                    Spacer()
                    Button("Quit") { engine.stop(); NSApp.terminate(nil) }
                }
                Text("Add delay to whichever device plays first (usually the non-Bluetooth ones) until the clicks line up.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 340)
            .onAppear { engine.refreshDevices() }
    }
}
