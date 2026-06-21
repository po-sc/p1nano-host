// host — MCU-хост для iCON P1-Nano: пульт управления маком.
//
//   ./host "P1Sim"     локальный тест против симулятора
//   ./host "Порт 3"    на железе (DAW-слот под мак, режим Ableton Live)
//   DBG=1 ./host ...   подробный лог (включая поток pitch фейдера)
//
// ВОЗМОЖНОСТИ:
//   • фейдер  -> громкость macOS (плавно, CoreAudio, до 100%), двусторонне (мотор едет за громкостью)
//   • HUD-плашка громкости на экране (приватный OSDManager)
//   • LCD устройства показывает текущую громкость числом + полоской
//   • кнопки -> Play/Pause, предыдущий/следующий трек, Mute, запуск приложений
//   • энкодер -> яркость экрана (и громкость на 8-м), относительные V-Pot
//
// АРХИТЕКТУРА ПОТОКОВ (критично — иначе падает):
//   MIDI-поток ТОЛЬКО парсит байты (running-status) и кладёт состояние под NSLock.
//   Вся тяжёлая работа (CoreAudio/AppKit/OSD/launch) — на ГЛАВНОМ потоке через таймер 30 Гц.
import CoreMIDI
import Foundation
import CoreAudio
import AppKit
import ObjectiveC
import ApplicationServices

// AppKit-контекст для фонового агента. .accessory = без иконки в доке, НО окна разрешены
// (OSD-плашке нужно окно; .prohibited её блокировал). Медиа теперь через MediaRemote — NSEvent не нужен.
let nsApp = NSApplication.shared
nsApp.setActivationPolicy(.accessory)

let DEBUG = ProcessInfo.processInfo.environment["DBG"] != nil
// DRYRUN: бесшумный тест-режим. Громкость/Mute хранятся в файлах-заглушках, реальный мак
// НЕ трогается; медиа-клавиши/HUD/запуск приложений становятся no-op (только лог).
let DRYRUN = ProcessInfo.processInfo.environment["DRYRUN"] != nil
let DRYFILE = "/tmp/p1nano_fakevol"
let DRYMUTE = "/tmp/p1nano_fakemute"
func log(_ s: String) { FileHandle.standardOutput.write(("[host] " + s + "\n").data(using: .utf8)!) }

// ============================================================================
// ПРИВЯЗКИ (меняй тут). Ноты — стандартные MCU; на железе подтверждены 93/94/104.
// Лог печатает КАЖДОЕ нажатие с нотой — легко сверить и поменять.
// ============================================================================
enum Action {
    case playPause, nextTrack, prevTrack, muteToggle, micMuteToggle
    case launch(String)            // открыть приложение по имени
    case run(String)               // выполнить shell-команду (макрос): URL, Shortcut, скрипт, AppleScript
}
// Кнопка (note on) -> действие. Это ДЕФОЛТЫ; их можно переопределить файлом
// ~/.config/p1nano/mapping.conf (без пересборки) — см. loadConfig() ниже и MAPPING.md.
var NOTE_ACTIONS: [UInt8: Action] = [
    94: .playPause,                // Play
    93: .playPause,                // Stop (тоже пауза — удобно)
    91: .prevTrack,                // Rewind  -> предыдущий трек
    92: .nextTrack,                // FFwd    -> следующий трек
    16: .muteToggle,               // MUTE (физическая кнопка, MCU Mute ch1) -> системный звук
    8:  .micMuteToggle,            // SOLO (MCU Solo ch1) -> мьют МИКРОФОНА (созвоны)
    95: .muteToggle,               // Record  -> тоже Mute
    // Ряд автоматизации read/write/trim/touch/latch/off (MCU ноты 74..79) -> запуск приложений.
    // ПОМЕНЯЙ названия под свои приложения (точные имена из /Applications):
    74: .launch("Safari"),         // READ/OFF  (стоковые приложения — поменяй под себя)
    75: .launch("Music"),          // WRITE
    76: .launch("Finder"),         // TRIM
    77: .launch("Notes"),          // TOUCH
    78: .launch("Calendar"),       // LATCH
    79: .launch("System Settings"),// GROUP
]
// Энкодеры (V-Pot, относительный CC ch1). CC16=энкодер1 … CC23=энкодер8.
enum EncTarget { case brightness, volume, none }
var ENC_TARGETS: [UInt8: EncTarget] = [
    16: .brightness,               // энкодер 1 -> яркость экрана
    23: .volume,                   // энкодер 8 -> громкость (бонус, дублирует фейдер)
]

// Загрузка привязок из ~/.config/p1nano/mapping.conf (переопределяет дефолты, без пересборки).
// Формат строк:  note <N> playpause|nexttrack|prevtrack|mute
//                note <N> launch <ИмяПриложения>
//                note <N> run <shell-команда>
//                enc <CC> brightness|volume|none
//                unmap note <N>  |  unmap enc <CC>
func parseAction(_ verb: String, _ arg: String) -> Action? {
    switch verb {
    case "playpause": return .playPause
    case "nexttrack": return .nextTrack
    case "prevtrack": return .prevTrack
    case "mute":      return .muteToggle
    case "micmute":   return .micMuteToggle
    case "launch":    return arg.isEmpty ? nil : .launch(arg)
    case "run":       return arg.isEmpty ? nil : .run(arg)
    default:          return nil
    }
}
func loadConfig() {
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".config/p1nano/mapping.conf")
    guard let txt = try? String(contentsOfFile: path, encoding: .utf8) else {
        log("конфиг привязок не найден (\(path)) — дефолты"); return
    }
    var count = 0
    for raw in txt.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let p = line.split(separator: " ").map(String.init)
        guard p.count >= 2 else { continue }
        if p[0] == "note", p.count >= 3, let n = UInt8(p[1]) {
            let arg = p.count > 3 ? p[3...].joined(separator: " ") : ""
            if let a = parseAction(p[2], arg) { NOTE_ACTIONS[n] = a; count += 1 }
        } else if p[0] == "enc", p.count >= 3, let c = UInt8(p[1]) {
            switch p[2] {
            case "brightness": ENC_TARGETS[c] = .brightness; count += 1
            case "volume":     ENC_TARGETS[c] = .volume; count += 1
            case "none":       ENC_TARGETS[c] = EncTarget.none; count += 1
            default: break }
        } else if p[0] == "unmap", p.count >= 3 {
            if p[1] == "note", let n = UInt8(p[2]) { NOTE_ACTIONS[n] = nil; count += 1 }
            if p[1] == "enc",  let c = UInt8(p[2]) { ENC_TARGETS[c] = nil; count += 1 }
        }
    }
    log("конфиг привязок применён: \(count) строк из \(path)")
}
loadConfig()

// ======================= ГРОМКОСТЬ + MUTE (CoreAudio) — только с главного потока ============
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
    if DRYRUN { return (try? String(contentsOfFile: DRYFILE, encoding: .utf8))
        .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 50 }
    caDevice = defaultOutDevice()
    var v: Float = 0.5; var size = UInt32(MemoryLayout<Float>.size)
    var a = volAddr(kAudioObjectPropertyElementMain)
    if AudioObjectHasProperty(caDevice, &a) { AudioObjectGetPropertyData(caDevice, &a, 0, nil, &size, &v) }
    else { var a1 = volAddr(1); if AudioObjectHasProperty(caDevice, &a1) { AudioObjectGetPropertyData(caDevice, &a1, 0, nil, &size, &v) } }
    return Int((v * 100).rounded())
}
func applyScalar(_ scalar: Float) {
    var v = max(0, min(1, scalar))
    if DRYRUN { try? String(Int((v*100).rounded())).write(toFile: DRYFILE, atomically: true, encoding: .utf8); return }
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
func muteAddr() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
}
var savedVolForMute = 0
func getMute() -> Bool {
    if DRYRUN { return ((try? String(contentsOfFile: DRYMUTE, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)) == "1" }
    caDevice = defaultOutDevice()
    var a = muteAddr(); var m: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
    if AudioObjectHasProperty(caDevice, &a) { AudioObjectGetPropertyData(caDevice, &a, 0, nil, &size, &m); return m != 0 }
    return getVol() == 0                          // фолбэк: устройство без Mute -> mute = громкость 0
}
func toggleMicMute() {                             // мьют МИКРОФОНА (для созвонов)
    if DRYRUN { return }
    var dev = AudioObjectID(0); var ds = UInt32(MemoryLayout<AudioObjectID>.size)
    var da = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &da, 0, nil, &ds, &dev)
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(dev, &a) else { log("микрофон без Mute-свойства"); return }
    var m: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &m)
    var nm: UInt32 = m != 0 ? 0 : 1
    AudioObjectSetPropertyData(dev, &a, 0, nil, size, &nm)
    log("микрофон \(nm != 0 ? "MUTED" : "вкл")")
}
func toggleMute() {
    if DRYRUN { try? String(getMute() ? "0" : "1").write(toFile: DRYMUTE, atomically: true, encoding: .utf8); return }
    caDevice = defaultOutDevice()
    var a = muteAddr()
    if AudioObjectHasProperty(caDevice, &a) {     // штатный Mute
        var m: UInt32 = getMute() ? 0 : 1
        AudioObjectSetPropertyData(caDevice, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    } else {                                      // фолбэк: громкость 0 / восстановить
        let cur = getVol()
        if cur > 0 { savedVolForMute = cur; applyScalar(0) }
        else { applyScalar(Float(max(savedVolForMute, 15)) / 100.0) }
    }
}

// ======================= HUD-плашка + медиа-клавиши + запуск приложений ======================
dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_NOW)
let osdMgr: AnyObject? = (NSClassFromString("OSDManager") as AnyObject?)?
    .perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue()
let osdSel = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
typealias OSDFn = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void
let osdFn: OSDFn? = {
    guard let mgr = osdMgr, let m = class_getInstanceMethod(object_getClass(mgr), osdSel) else { return nil }
    return unsafeBitCast(method_getImplementation(m), to: OSDFn.self)
}()
func showOSD(image: Int64, level: Double) {       // level 0..1; image: 1=яркость, 3=громкость, 4=mute
    if DRYRUN { return }
    guard let mgr = osdMgr, let fn = osdFn else { return }
    let total: UInt32 = 16
    let filled = UInt32((max(0,min(1,level))*16.0).rounded())
    fn(mgr, osdSel, image, CGMainDisplayID(), 0x1f4, 1500, filled, total, false)
}
func showVolumeHUD(_ volume: Int, muted: Bool) { showOSD(image: muted ? 4 : 3, level: muted ? 0 : Double(volume)/100.0) }
func showBrightnessHUD(_ level: Double) { showOSD(image: 1, level: level) }

// МЕДИА через MediaRemote (приватный) — Play/Pause/треки системно, БЕЗ Accessibility.
let mrHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
typealias MRSendFn = @convention(c) (Int32, CFDictionary?) -> Bool
let mrSend: MRSendFn? = mrHandle.flatMap { dlsym($0, "MRMediaRemoteSendCommand") }.map { unsafeBitCast($0, to: MRSendFn.self) }
let MR_TOGGLE: Int32 = 2, MR_NEXT: Int32 = 4, MR_PREV: Int32 = 5   // команды MediaRemote
func mediaCommand(_ cmd: Int32) { if DRYRUN { return }; _ = mrSend?(cmd, nil) }

// ЯРКОСТЬ через DisplayServices (приватный) — встроенный дисплей, БЕЗ Accessibility.
let dsHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
typealias DSGetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
typealias DSSetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
let dsGet: DSGetFn? = dsHandle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: DSGetFn.self) }
let dsSet: DSSetFn? = dsHandle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: DSSetFn.self) }
func adjustBrightness(_ delta: Float) {
    if DRYRUN || delta == 0 { return }
    let d = CGMainDisplayID(); var b: Float = 0.5
    _ = dsGet?(d, &b)
    b = max(0, min(1, b + delta))
    _ = dsSet?(d, b)
    showBrightnessHUD(Double(b))                  // плашка яркости на маке, как у громкости
}

func launchApp(_ name: String) {
    if DRYRUN { return }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", name]
    try? p.run()
}
func runShell(_ cmd: String) {   // макрос: любая команда, напр. "open https://...", "shortcuts run Имя", "osascript -e ..."
    if DRYRUN { return }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
    try? p.run()
}

// ======================= ОБЩЕЕ СОСТОЯНИЕ (под локом — мост между потоками) ===================
let lock = NSLock()
var touchHeld = false
var pendingScalar: Float = -1
var lastRawPos = 8192
var releaseHold = false
var pendingActions: [Action] = []          // нажатия кнопок к обработке
var pendingBrightUp = 0, pendingBrightDown = 0   // тики энкодера яркости
var pendingVolUp = 0, pendingVolDown = 0         // тики энкодера громкости

// ======================= MIDI =======================
let portMatch = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Порт 3"
func nm(_ r: MIDIEndpointRef) -> String {
    var cf: Unmanaged<CFString>?; MIDIObjectGetStringProperty(r, kMIDIPropertyDisplayName, &cf)
    return (cf?.takeRetainedValue() as String?) ?? "?"
}
// notify-колбэк: при любом изменении MIDI-сетапа (включили/выключили iCON) — переподключаемся.
// Это убирает «зомби-хост» и позволяет автозапуску работать независимо от порядка включения.
var client = MIDIClientRef()
MIDIClientCreateWithBlock("p1host" as CFString, &client) { notif in
    let t = notif.pointee.messageID
    if t == .msgSetupChanged || t == .msgObjectAdded || t == .msgObjectRemoved { refreshConnection() }
}
var outPort = MIDIPortRef(); MIDIOutputPortCreate(client, "o" as CFString, &outPort)
func findPorts() -> (MIDIEndpointRef, MIDIEndpointRef) {
    var s: MIDIEndpointRef = 0, d: MIDIEndpointRef = 0
    for i in 0..<MIDIGetNumberOfSources() { let e = MIDIGetSource(i); if nm(e).contains(portMatch) { s = e } }
    for i in 0..<MIDIGetNumberOfDestinations() { let e = MIDIGetDestination(i); if nm(e).contains(portMatch) { d = e } }
    return (s, d)
}
var src: MIDIEndpointRef = 0, dst: MIDIEndpointRef = 0
var connected = false
func send(_ bytes: [UInt8]) {
    guard connected, dst != 0 else { return }
    var pl = MIDIPacketList(); let p = MIDIPacketListInit(&pl)
    _ = MIDIPacketListAdd(&pl, 256, p, 0, bytes.count, bytes); MIDISend(outPort, dst, &pl)
}
func pitchBytes(_ pos: Int) -> [UInt8] {
    let p = max(0, min(16383, pos)); return [0xE0, UInt8(p & 0x7F), UInt8((p >> 7) & 0x7F)]
}
func volToPitch(_ v: Int) -> [UInt8] { pitchBytes(Int(Double(max(0,min(100,v))) / 100.0 * 16383.0)) }

// ======================= ПОТОКОВЫЙ MIDI-ПАРСЕР (running-status) =======================
var runStatus: UInt8 = 0, dataBuf: [UInt8] = [], inSysex = false
func handleMessage(_ status: UInt8, _ d: [UInt8]) {
    let type = status & 0xF0, ch = status & 0x0F
    if type == 0xE0, ch == 0, d.count == 2 {                 // pitch ch1 = фейдер
        let pos = min(16383, Int(d[0]) | (Int(d[1]) << 7))
        lock.lock(); if touchHeld { lastRawPos = pos; pendingScalar = Float(pos) / 16383.0 }; lock.unlock()
    } else if type == 0x90, ch == 0, d.count == 2 {          // note on/off ch1 = кнопки/касание
        let note = d[0], vel = d[1]
        if note == 0x68 {                                    // касание фейдера (нота 104)
            lock.lock(); if vel != 0 { touchHeld = true } else { touchHeld = false; releaseHold = true }; lock.unlock()
        } else if vel != 0 {                                 // нажатие кнопки
            if let act = NOTE_ACTIONS[note] { lock.lock(); pendingActions.append(act); lock.unlock() }
            log("кнопка нота \(note)\(NOTE_ACTIONS[note] != nil ? " -> действие" : " (не назначена)")")
        }
    } else if type == 0xB0, ch == 0, d.count == 2 {          // CC ch1 = энкодеры (V-Pot, относит.)
        let cc = d[0], val = d[1]
        let ccw = (val & 0x40) != 0
        let ticks = Int(ccw ? (val & 0x3F) : (val & 0x7F))
        let tgt = ENC_TARGETS[cc] ?? .none
        switch tgt {
        case .brightness: lock.lock(); if ccw { pendingBrightDown += ticks } else { pendingBrightUp += ticks }; lock.unlock()
        case .volume:     lock.lock(); if ccw { pendingVolDown += ticks }    else { pendingVolUp += ticks };    lock.unlock()
        case .none: break
        }
        log("энкодер CC\(cc) \(ccw ? "-" : "+")\(ticks)\(tgt == .none ? " (не назначен)" : "")")
    }
}
func feedByte(_ byte: UInt8) {
    if byte >= 0x80 {
        if byte >= 0xF8 { return }
        if byte == 0xF0 { inSysex = true; runStatus = 0; dataBuf = []; return }
        if byte == 0xF7 { inSysex = false; runStatus = 0; dataBuf = []; return }
        if byte >= 0xF1 && byte <= 0xF6 { runStatus = 0; dataBuf = []; return }
        runStatus = byte; dataBuf = []; return
    }
    if inSysex { return }
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
// подключение/переподключение — вызывается из notify-колбэка и один раз на старте
func refreshConnection() {
    guard inPort != 0 else { return }
    let (s, d) = findPorts()
    if s != 0 && d != 0 {
        if !connected || s != src || d != dst {
            if connected && src != 0 { MIDIPortDisconnectSource(inPort, src) }
            src = s; dst = d
            MIDIPortConnectSource(inPort, src, nil)
            connected = true
            log("подключён к \(nm(src))")
            sendInitOnce(); sendKeepalive()
        }
    } else if connected {
        connected = false; src = 0; dst = 0
        log("устройство пропало — жду включения")
    }
}

// ======================= БУДИЛКА (online) + LCD =======================
func lcd(_ offset: UInt8, _ text: String) -> [UInt8] {
    var s = Array(text.utf8); if s.count > 28 { s = Array(s.prefix(28)) }; while s.count < 28 { s.append(0x20) }
    return [0xF0,0x00,0x00,0x66,0x14,0x12,offset] + s + [0xF7]
}
var lastLcdVol = -1, lastLcdMute = false
func centered(_ s: String, _ width: Int = 28) -> String {   // текст по центру строки LCD
    if s.count >= width { return String(s.prefix(width)) }
    let pad = width - s.count, left = pad / 2
    return String(repeating: " ", count: left) + s + String(repeating: " ", count: pad - left)
}
func renderLCD(_ v: Int, _ muted: Bool) {           // всегда шлёт обе строки (лево-выравнивание!)
    send(lcd(0x00, muted ? "Mac MUTED" : "Mac Vol \(v)%"))
    send(lcd(0x38, muted ? "  ---" : "  \(v) %"))
}
func updateLCD(_ v: Int, _ muted: Bool) {           // шлёт только при изменении
    if v == lastLcdVol && muted == lastLcdMute { return }
    lastLcdVol = v; lastLcdMute = muted
    renderLCD(v, muted)
}
func sendInitOnce() {
    for ch in 0..<8 { send([0xF0,0x00,0x00,0x66,0x14,0x20,UInt8(ch),0x00,0xF7]) }
    for n in 0...127 { send([0x90, UInt8(n), 0x00]) }
    lastLcdVol = -1; updateLCD(getVol(), getMute())
}
var kaCount = 0
func sendKeepalive() {
    for ch in 0..<8 { send([0xF0,0x00,0x00,0x66,0x14,0x20,UInt8(ch),0x01,0xF7]) }
    send([0xF0,0x00,0x00,0x66,0x14,0x13,0x00,0xF7])
    for m in 0..<8 { send([0xD0, UInt8(m << 4)]) }
    kaCount += 1
    if connected && kaCount % 4 == 0 { renderLCD(getVol(), getMute()) }   // держим индикатор на экране (~1с)
}

// ======================= ГЛАВНЫЙ ТАЙМЕР (30 Гц): вся тяжёлая работа на главном потоке =======
var vol = getVol()
var lastFedVol = vol
var lastAppliedVol = -1
func applyTick() {
    lock.lock()
    let scalar = pendingScalar; pendingScalar = -1
    let doRelease = releaseHold; releaseHold = false
    let rawPos = lastRawPos
    let acts = pendingActions; pendingActions = []
    let bUp = pendingBrightUp, bDown = pendingBrightDown; pendingBrightUp = 0; pendingBrightDown = 0
    let vUp = pendingVolUp, vDown = pendingVolDown; pendingVolUp = 0; pendingVolDown = 0
    lock.unlock()

    // фейдер -> громкость (берём последнее значение -> плавно)
    if scalar >= 0 {
        var s = scalar; if s > 0.97 { s = 1.0 }; if s < 0.02 { s = 0.0 }
        applyScalar(s)
        let nv = Int((s * 100).rounded())
        if nv != lastAppliedVol {
            lastAppliedVol = nv; vol = nv; lastFedVol = nv
            showVolumeHUD(nv, muted: false); updateLCD(nv, false)
            if DEBUG { log("ФЕЙДЕР -> громкость \(nv)") }
        }
    }
    if doRelease { send(pitchBytes(rawPos)); lastFedVol = vol }

    // энкодер громкости -> шагаем по 2%
    if vUp + vDown > 0 {
        var nv = getVol() + (vUp - vDown) * 2; nv = max(0, min(100, nv))
        applyScalar(Float(nv)/100.0); vol = nv; lastAppliedVol = nv; lastFedVol = nv
        showVolumeHUD(nv, muted: false); updateLCD(nv, false)
    }
    // энкодер яркости -> DisplayServices (1/16 за тик, итоговая дельта одним вызовом)
    if bUp + bDown > 0 { adjustBrightness(Float(bUp - bDown) * 0.0625) }

    // кнопки
    for act in acts {
        switch act {
        case .playPause: mediaCommand(MR_TOGGLE); log("Play/Pause")
        case .nextTrack: mediaCommand(MR_NEXT); log("следующий трек")
        case .prevTrack: mediaCommand(MR_PREV); log("предыдущий трек")
        case .muteToggle:
            toggleMute(); let m = getMute(); showVolumeHUD(getVol(), muted: m); updateLCD(getVol(), m)
            log("Mute \(m ? "ON" : "OFF")")
        case .micMuteToggle: toggleMicMute()
        case .launch(let app): launchApp(app); log("запуск приложения: \(app)")
        case .run(let cmd): runShell(cmd); log("макрос: \(cmd)")
        }
    }
}

// ======================= ОБРАТНАЯ СВЯЗЬ: громкость -> фейдер =======================
func feedbackTick() {
    lock.lock(); let held = touchHeld; lock.unlock()
    if held { return }
    let cur = getVol(); let muted = getMute()
    if cur != lastFedVol {
        send(volToPitch(cur)); lastFedVol = cur; vol = cur; lastAppliedVol = cur
        updateLCD(cur, muted)
        if DEBUG { log("TX мотор -> \(cur)") }
    }
}

refreshConnection()
if !connected { log("жду устройство (порт '\(portMatch)') — подключусь автоматически при включении") }
Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { _ in applyTick() }
Timer.scheduledTimer(withTimeInterval: 0.10,  repeats: true) { _ in feedbackTick() }
Timer.scheduledTimer(withTimeInterval: 0.25,  repeats: true) { _ in sendKeepalive() }

log("MCU-хост запущен. Фейдер<->громкость, LCD, HUD=\(osdFn != nil ? "вкл" : "выкл"), кнопки/энкодеры активны.")
log("MediaRemote=\(mrSend != nil ? "ок" : "НЕТ"), DisplayServices=\(dsSet != nil ? "ок" : "НЕТ") (без Accessibility)")
RunLoop.main.run()
