// host — MCU-хост для iCON P1-Nano: двусторонний мост фейдер <-> громкость macOS,
// с HUD-плашкой громкости и кнопкой Play/Pause.
//
//   ./host "P1Sim"     локальный тест против симулятора
//   ./host "Порт 3"    на железе (DAW-слот под мак, режим Ableton Live)
//   DBG=1 ./host ...   подробный лог
//
// АРХИТЕКТУРА (важно — из-за этого раньше падало):
//   • MIDI-поток (CoreMIDI callback) ТОЛЬКО парсит байты и кладёт состояние под локом.
//     Никакого CoreAudio/AppKit/OSDManager оттуда — они не потокобезопасны и роняли процесс.
//   • Главный поток через таймер 30 Гц забирает состояние и делает всю тяжёлую работу:
//     ставит громкость, рисует HUD, шлёт Play/Pause, двигает мотор. Так нет ни крашей, ни рывков.
//   • Парсер MIDI — настоящий потоковый, с running-status (быстрый фейдер слипает пакеты).
import CoreMIDI
import Foundation
import CoreAudio
import AppKit
import ObjectiveC

let DEBUG = ProcessInfo.processInfo.environment["DBG"] != nil
func log(_ s: String) { FileHandle.standardOutput.write(("[host] " + s + "\n").data(using: .utf8)!) }

// ======================= ГРОМКОСТЬ macOS (CoreAudio) — только с главного потока =======================
func defaultOutDevice() -> AudioObjectID {
    var dev = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
    return dev
}
var caDevice = defaultOutDevice()
func volAddr(_ el: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput, mElement: el)
}
func getVol() -> Int {
    caDevice = defaultOutDevice()
    var v: Float = 0.5; var size = UInt32(MemoryLayout<Float>.size)
    var a = volAddr(kAudioObjectPropertyElementMain)
    if AudioObjectHasProperty(caDevice, &a) { AudioObjectGetPropertyData(caDevice, &a, 0, nil, &size, &v) }
    else { var a1 = volAddr(1); if AudioObjectHasProperty(caDevice, &a1) { AudioObjectGetPropertyData(caDevice, &a1, 0, nil, &size, &v) } }
    return Int((v * 100).rounded())
}
func applyScalar(_ scalar: Float) {
    var v = max(0, min(1, scalar))
    var main = volAddr(kAudioObjectPropertyElementMain)
    if AudioObjectHasProperty(caDevice, &main) {
        AudioObjectSetPropertyData(caDevice, &main, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
    } else {
        for ch in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            var a = volAddr(ch)
            if AudioObjectHasProperty(caDevice, &a) {
                AudioObjectSetPropertyData(caDevice, &a, 0, nil, UInt32(MemoryLayout<Float>.size), &v)
            }
        }
    }
}

// ======================= HUD-плашка громкости (приватный OSDManager) — только с главного потока =======
dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_NOW)
let osdMgr: AnyObject? = (NSClassFromString("OSDManager") as AnyObject?)?
    .perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue()
let osdSel = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
typealias OSDFn = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void
let osdFn: OSDFn? = {
    guard let mgr = osdMgr, let m = class_getInstanceMethod(object_getClass(mgr), osdSel) else { return nil }
    return unsafeBitCast(method_getImplementation(m), to: OSDFn.self)
}()
func showVolumeHUD(_ volume: Int) {
    guard let mgr = osdMgr, let fn = osdFn else { return }
    let total: UInt32 = 16
    let filled = UInt32((Double(max(0,min(100,volume)))/100.0*16.0).rounded())
    fn(mgr, osdSel, 3, CGMainDisplayID(), 0x1f4, 1500, filled, total, false)
}

// ======================= Play/Pause (медиа-клавиша) — только с главного потока =======================
func mediaKey(_ keyType: Int32) {
    func post(_ down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = Int((keyType << 16) | ((down ? 0xa : 0xb) << 8))
        if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) {
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }
    post(true); post(false)
}
let NX_PLAY: Int32 = 16
// Ноты кнопок -> Play/Pause. Реальное железо в режиме Ableton шлёт 93 (Stop) / 94 (Play).
let PLAY_NOTES: Set<UInt8> = [91, 92, 93, 94, 95]

// ======================= ОБЩЕЕ СОСТОЯНИЕ (под локом — мост между потоками) =======================
let lock = NSLock()
var touchHeld = false           // фейдера касаются
var pendingScalar: Float = -1   // новая позиция фейдера к применению (-1 = нет)
var lastRawPos = 8192           // последняя сырая позиция (для точного удержания мотором)
var releaseHold = false         // фейдер отпустили -> удержать lastRawPos мотором
var pendingPlay = 0             // нажатий Play к обработке

// ======================= MIDI =======================
let portMatch = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Порт 3"
func nm(_ r: MIDIEndpointRef) -> String {
    var cf: Unmanaged<CFString>?; MIDIObjectGetStringProperty(r, kMIDIPropertyDisplayName, &cf)
    return (cf?.takeRetainedValue() as String?) ?? "?"
}
var client = MIDIClientRef(); MIDIClientCreate("p1host" as CFString, nil, nil, &client)
var outPort = MIDIPortRef(); MIDIOutputPortCreate(client, "o" as CFString, &outPort)
func findPorts() -> (MIDIEndpointRef, MIDIEndpointRef) {
    var s: MIDIEndpointRef = 0, d: MIDIEndpointRef = 0
    for i in 0..<MIDIGetNumberOfSources() { let e = MIDIGetSource(i); if nm(e).contains(portMatch) { s = e } }
    for i in 0..<MIDIGetNumberOfDestinations() { let e = MIDIGetDestination(i); if nm(e).contains(portMatch) { d = e } }
    return (s, d)
}
var src: MIDIEndpointRef = 0, dst: MIDIEndpointRef = 0
(src, dst) = findPorts()
while src == 0 || dst == 0 {
    log("жду устройство (порт '\(portMatch)')...")
    Thread.sleep(forTimeInterval: 2.0)
    (src, dst) = findPorts()
}
log("подключён к \(nm(src))")
func send(_ bytes: [UInt8]) {
    var pl = MIDIPacketList(); let p = MIDIPacketListInit(&pl)
    _ = MIDIPacketListAdd(&pl, 256, p, 0, bytes.count, bytes); MIDISend(outPort, dst, &pl)
}
func pitchBytes(_ pos: Int) -> [UInt8] {
    let p = max(0, min(16383, pos))
    return [0xE0, UInt8(p & 0x7F), UInt8((p >> 7) & 0x7F)]
}
func volToPitch(_ v: Int) -> [UInt8] {
    return pitchBytes(Int(Double(max(0,min(100,v))) / 100.0 * 16383.0))
}

// ======================= ПОТОКОВЫЙ MIDI-ПАРСЕР (running-status) =======================
// Вызывается из MIDI-потока. Только парсит и кладёт состояние под локом. Без CoreAudio/AppKit!
var runStatus: UInt8 = 0
var dataBuf: [UInt8] = []
var inSysex = false
func handleMessage(_ status: UInt8, _ d: [UInt8]) {
    let type = status & 0xF0, ch = status & 0x0F
    if type == 0xE0, ch == 0, d.count == 2 {                 // pitch ch1 = фейдер
        let pos = min(16383, Int(d[0]) | (Int(d[1]) << 7))
        lock.lock()
        if touchHeld { lastRawPos = pos; pendingScalar = Float(pos) / 16383.0 }
        lock.unlock()
    } else if type == 0x90, ch == 0, d.count == 2 {          // note on/off ch1
        let note = d[0], vel = d[1]
        if note == 0x68 {                                    // касание фейдера (нота 104)
            lock.lock()
            if vel != 0 { touchHeld = true }
            else { touchHeld = false; releaseHold = true }
            lock.unlock()
        } else if vel != 0, PLAY_NOTES.contains(note) {      // кнопка Play/Stop
            lock.lock(); pendingPlay += 1; lock.unlock()
        }
    }
}
func feedByte(_ byte: UInt8) {
    if byte >= 0x80 {                                        // статус-байт
        if byte >= 0xF8 { return }                          // realtime — не трогает running-status
        if byte == 0xF0 { inSysex = true; runStatus = 0; dataBuf = []; return }
        if byte == 0xF7 { inSysex = false; runStatus = 0; dataBuf = []; return }
        if byte >= 0xF1 && byte <= 0xF6 { runStatus = 0; dataBuf = []; return }  // system common
        runStatus = byte; dataBuf = []                       // channel voice
        return
    }
    if inSysex { return }                                    // данные внутри sysex — пропускаем
    if runStatus == 0 { return }
    dataBuf.append(byte)
    let need = ((runStatus & 0xF0) == 0xC0 || (runStatus & 0xF0) == 0xD0) ? 1 : 2
    if dataBuf.count >= need { handleMessage(runStatus, dataBuf); dataBuf = [] }
}

var inPort = MIDIPortRef()
MIDIInputPortCreateWithBlock(client, "i" as CFString, &inPort) { (lp, _) in
    var pk = lp.pointee.packet
    for _ in 0..<lp.pointee.numPackets {
        let n = min(Int(pk.length), 256)
        withUnsafeBytes(of: pk.data) { raw in for i in 0..<n { feedByte(raw[i]) } }
        pk = MIDIPacketNext(&pk).pointee
    }
}
let connErr = MIDIPortConnectSource(inPort, src, nil)
log("MIDIPortConnectSource статус = \(connErr) (0 = ок)")

// ======================= БУДИЛКА (online) =======================
func lcd(_ offset: UInt8, _ text: String) -> [UInt8] {
    var s = Array(text.utf8); while s.count < 28 { s.append(0x20) }
    return [0xF0,0x00,0x00,0x66,0x14,0x12,offset] + s + [0xF7]
}
func sendInitOnce() {
    send(lcd(0x00, "Mac Volume"))
    send(lcd(0x38, "Fader = volume"))
    for ch in 0..<8 { send([0xF0,0x00,0x00,0x66,0x14,0x20,UInt8(ch),0x00,0xF7]) }
    for n in 0...127 { send([0x90, UInt8(n), 0x00]) }
}
func sendKeepalive() {
    for ch in 0..<8 { send([0xF0,0x00,0x00,0x66,0x14,0x20,UInt8(ch),0x01,0xF7]) }
    send([0xF0,0x00,0x00,0x66,0x14,0x13,0x00,0xF7])
    for m in 0..<8 { send([0xD0, UInt8(m << 4)]) }
}

// ======================= ГЛАВНЫЙ ТАЙМЕР (30 Гц): вся тяжёлая работа здесь, на главном потоке =====
var vol = getVol()
var lastFedVol = vol
var lastAppliedVol = -1
func applyTick() {
    // забираем состояние под локом
    lock.lock()
    let scalar = pendingScalar; pendingScalar = -1
    let held = touchHeld
    let doRelease = releaseHold; releaseHold = false
    let rawPos = lastRawPos
    let plays = pendingPlay; pendingPlay = 0
    lock.unlock()

    // фейдер -> громкость (берём только последнее значение -> плавно, без флуда)
    if scalar >= 0 {
        var s = scalar
        if s > 0.97 { s = 1.0 }; if s < 0.02 { s = 0.0 }
        applyScalar(s)
        let nv = Int((s * 100).rounded())
        if nv != lastAppliedVol {
            lastAppliedVol = nv; vol = nv; lastFedVol = nv
            showVolumeHUD(nv)
            if DEBUG { log("ФЕЙДЕР -> громкость \(nv)") }
        }
    }
    // фейдер отпустили -> удержать мотором ТОЧНУЮ позицию (без подёргиваний)
    if doRelease { send(pitchBytes(rawPos)); lastFedVol = vol }
    // Play/Pause
    if plays > 0 { mediaKey(NX_PLAY); if DEBUG { log("Play/Pause x\(plays)") }; _ = held }
}

// ======================= ОБРАТНАЯ СВЯЗЬ: громкость -> фейдер =======================
func feedbackTick() {
    lock.lock(); let held = touchHeld; lock.unlock()
    if held { return }                                       // ведёшь фейдер — мотор не трогаем
    let cur = getVol()
    if cur != lastFedVol {
        send(volToPitch(cur))
        if DEBUG { log("TX мотор -> \(cur)") }
        lastFedVol = cur; vol = cur; lastAppliedVol = cur
    }
}

sendInitOnce()
sendKeepalive()
Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { _ in applyTick() }     // 30 Гц
Timer.scheduledTimer(withTimeInterval: 0.10,  repeats: true) { _ in feedbackTick() }
Timer.scheduledTimer(withTimeInterval: 0.25,  repeats: true) { _ in sendKeepalive() }

log("MCU-хост запущен: фейдер<->громкость, HUD=\(osdFn != nil ? "вкл" : "выкл"), Play/Pause на нотах \(PLAY_NOTES.sorted()).")
RunLoop.main.run()
