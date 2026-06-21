// devicesim — локальный симулятор iCON P1-Nano (по перехватам MIDI Monitor).
// Создаёт виртуальный MIDI-порт "P1Sim" (source+destination), чтобы тестировать host
// БЕЗ железа. Моделирует наблюдённое поведение:
//   - пингует F0 00 00 66 14 01 F7 каждые 2с (всегда, как реальное устройство на всех портах)
//   - "онлайн" становится, когда host шлёт MCU-поток (14 20 метеры / 14 13 fw)
//   - на 14 13 (fw request) онлайн отвечает 14 14 <версия>
//   - симулирует движение фейдера: ОНЛАЙН -> touch(G#6) + поток Pitch ch1; ОФФЛАЙН -> только touch
import CoreMIDI
import Foundation

var client = MIDIClientRef(); MIDIClientCreate("p1sim" as CFString, nil, nil, &client)

var virtSrc = MIDIEndpointRef()                 // sim -> host
MIDISourceCreate(client, "P1Sim" as CFString, &virtSrc)

func toHost(_ bytes: [UInt8]) {
    var pl = MIDIPacketList(); let p = MIDIPacketListInit(&pl)
    _ = MIDIPacketListAdd(&pl, 1024, p, 0, bytes.count, bytes); MIDIReceived(virtSrc, &pl)
}
func log(_ s: String) { FileHandle.standardOutput.write(("[sim] " + s + "\n").data(using: .utf8)!) }

var online = false
var faderPos = 8192                              // текущая позиция физ.фейдера (0..16383)

var virtDst = MIDIEndpointRef()                  // host -> sim
MIDIDestinationCreateWithBlock(client, "P1Sim" as CFString, &virtDst) { (lp, _) in
    var pk = lp.pointee.packet
    for _ in 0..<lp.pointee.numPackets {
        let n = min(Int(pk.length), 256)
        let b = withUnsafeBytes(of: pk.data) { raw in (0..<n).map { raw[$0] } }
        if b.count >= 6, b[0]==0xF0, b[4]==0x14, (b[5]==0x20 || b[5]==0x13) {
            if !online { online = true; log("ОНЛАЙН (получил MCU-поток хоста)") }
            if b[5]==0x13 { toHost([0xF0,0x00,0x00,0x66,0x14,0x14,0x01,0x00,0x05,0xF7]) }  // fw reply
        }
        if b.count >= 3, (b[0] & 0xF0) == 0xE0, (b[0] & 0x0F) == 0 {                       // мотор-команда хоста (pitch ch1)
            let pos = Int(b[1]) | (Int(b[2]) << 7)
            faderPos = pos
            log("МОТОР позиция \(Int((Double(pos)/16383.0*100).rounded()))")
        }
        pk = MIDIPacketNext(&pk).pointee
    }
}

// фоновый пинг 14 01 каждые 2с (как реальное устройство)
Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
    toHost([0xF0,0x00,0x00,0x66,0x14,0x01,0xF7])
}

// симуляция движения фейдера пользователем
func moveFader(to target: Int) {
    toHost([0x90,0x68,0x7F])                     // touch on
    if online {
        var pos = faderPos
        let step = pos < target ? 250 : -250
        while abs(pos - target) > 250 {
            pos += step
            toHost([0xE0, UInt8(pos & 0x7F), UInt8((pos>>7) & 0x7F)])
            usleep(2000)
        }
        toHost([0xE0, UInt8(target & 0x7F), UInt8((target>>7) & 0x7F)])
        faderPos = target
        log("фейдер -> \(target) (онлайн, шлю Pitch ch1)")
    } else {
        log("фейдер двинут, но ОФФЛАЙН -> только касание, позиции нет")
    }
    toHost([0x90,0x68,0x00])                      // touch off
}

// сценарий движения фейдера (отключается аргументом "nofader" для теста обратной связи)
if !CommandLine.arguments.contains("nofader") {
    Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in moveFader(to: 1200) }
    Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { _ in moveFader(to: 15000) }
}
// тест кнопки Play (нота 94) по аргументу "button"
if CommandLine.arguments.contains("button") {
    Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
        log("жму кнопку Play (нота 94)"); toHost([0x90, 94, 0x7F]); toHost([0x90, 94, 0x00])
    }
}

// тест всех привязок (кнопки + энкодеры) по аргументу "suite"
func note(_ n: UInt8) { toHost([0x90, n, 0x7F]); toHost([0x90, n, 0x00]) }
func cc(_ c: UInt8, _ v: UInt8) { toHost([0xB0, c, v]) }
if CommandLine.arguments.contains("suite") {
    var t = 3.0
    for (n, name) in [(UInt8(94),"Play"),(91,"prev"),(92,"next"),(95,"mute"),(74,"app:Safari")] {
        let nn = n; let label = name
        Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in log("кнопка \(label) (нота \(nn))"); note(nn) }
        t += 0.4
    }
    // энкодер яркости CC16: +3 тика, потом -2 тика
    Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in log("энкодер1 яркость +3"); cc(16, 0x03) }; t += 0.4
    Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in log("энкодер1 яркость -2"); cc(16, 0x42) }; t += 0.4
    // энкодер громкости CC23: +4 тика
    Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in log("энкодер8 громкость +4"); cc(23, 0x04) }; t += 0.4
}

// СТРЕСС: шквал быстрых движений фейдера + долбёж кнопок/энкодеров (проверка многопоточности)
if CommandLine.arguments.contains("stress") {
    var n = 0
    Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
        guard online else { return }
        n += 1
        // быстрый свип фейдера во всю длину
        toHost([0x90,0x68,0x7F])
        var pos = (n % 2 == 0) ? 200 : 16200
        let target = (n % 2 == 0) ? 16200 : 200
        let step = pos < target ? 600 : -600
        while abs(pos - target) > 600 { pos += step; toHost([0xE0, UInt8(pos & 0x7F), UInt8((pos>>7) & 0x7F)]) }
        toHost([0x90,0x68,0x00])
        // долбёж кнопок и энкодеров вперемешку
        for note: UInt8 in [94,91,92,95,74,77] { toHost([0x90,note,0x7F]); toHost([0x90,note,0x00]) }
        toHost([0xB0,16, n%2==0 ? 0x05:0x45]); toHost([0xB0,23,0x03])
    }
}

log("симулятор P1-Nano запущен (порт P1Sim). Пингую 14 01, жду MCU-поток хоста.")
RunLoop.main.run()
