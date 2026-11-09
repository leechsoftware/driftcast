// Writes a PGS (.sup) subtitle file with a few text cues rendered by CoreText, for OCR tests.
import AppKit
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let cues: [(Double, Double, String)] = [(1, 4, "Hello from a picture subtitle"), (6, 9, "The quick brown fox jumps"), (12, 15, "Third line of PGS text")]
let W = 1280, H = 720

func render(_ text: String) -> (w: Int, h: Int, pixels: [UInt8]) {
    let font = NSFont.boldSystemFont(ofSize: 40)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let str = NSAttributedString(string: text, attributes: attrs)
    let size = str.size()
    let w = Int(size.width.rounded(.up)) + 16, h = Int(size.height.rounded(.up)) + 16
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.set(); NSRect(x: 0, y: 0, width: w, height: h).fill()
    str.draw(at: NSPoint(x: 8, y: 8))
    NSGraphicsContext.restoreGraphicsState()
    var px = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
        let c = rep.colorAt(x: x, y: y)!
        px[y * w + x] = c.alphaComponent > 0.5 ? 1 : 0   // palette index 1 = white text
    } }
    return (w, h, px)
}

func rle(_ w: Int, _ h: Int, _ px: [UInt8]) -> [UInt8] {
    var d: [UInt8] = []
    for y in 0..<h {
        var x = 0
        while x < w {
            let c = px[y * w + x]; var n = 1
            while x + n < w && px[y * w + x + n] == c { n += 1 }
            if c == 0 {
                if n < 64 { d += [0, UInt8(n)] } else { d += [0, 0x40 | UInt8(n >> 8), UInt8(n & 0xff)] }
            } else if n == 1 {
                d.append(c)
            } else if n < 64 {
                d += [0, 0x80 | UInt8(n), c]
            } else {
                d += [0, 0xC0 | UInt8(n >> 8), UInt8(n & 0xff), c]
            }
            x += n
        }
        d += [0, 0]
    }
    return d
}

var file = Data()
func seg(_ type: UInt8, _ pts: Double, _ payload: [UInt8]) {
    var h: [UInt8] = [0x50, 0x47]
    let t = UInt32(pts * 90000)
    h += [UInt8(t >> 24), UInt8((t >> 16) & 0xff), UInt8((t >> 8) & 0xff), UInt8(t & 0xff), 0, 0, 0, 0, type, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
    file.append(contentsOf: h + payload)
}
func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }

var comp = 0
for (start, end, text) in cues {
    let (w, h, px) = render(text)
    let x = (W - w) / 2, y = H - h - 40
    // PCS: epoch start with one object
    var pcs: [UInt8] = u16(W); pcs += u16(H); pcs += [0x10]; pcs += u16(comp); pcs += [0x80, 0, 0, 1]
    pcs += u16(0); pcs += [0, 0]; pcs += u16(x); pcs += u16(y)
    seg(0x16, start, pcs)
    var wds: [UInt8] = [1, 0]; wds += u16(x); wds += u16(y); wds += u16(w); wds += u16(h)
    seg(0x17, start, wds)
    seg(0x14, start, [0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255])            // PDS: 0 transparent, 1 white
    let data = rle(w, h, px)
    let len = data.count + 4
    var ods: [UInt8] = u16(0); ods += [0, 0xC0, UInt8(len >> 16), UInt8((len >> 8) & 0xff), UInt8(len & 0xff)]
    ods += u16(w); ods += u16(h); ods += data
    seg(0x15, start, ods)
    seg(0x80, start, [])
    comp += 1
    var clear: [UInt8] = u16(W); clear += u16(H); clear += [0x10]; clear += u16(comp); clear += [0x00, 0, 0, 0]
    seg(0x16, end, clear)
    seg(0x80, end, [])
    comp += 1
}
try! file.write(to: out)
print("wrote \(file.count) bytes, \(cues.count) cues")
