// make-background.swift — рисует фон для окна .dmg (заголовок + стрелка «перетащи
// в Applications»). Запуск:  swift assets/dmg/make-background.swift <out.png> [<out@2x.png>]
// Размер окна .dmg = WIN_W × WIN_H (см. build-dmg.sh). Картинка @1x в этом размере,
// @2x — вдвое крупнее для Retina (Finder сам подхватит по имени background@2x.png).
import AppKit

// Логический размер окна .dmg (координаты Finder — top-left).
let WIN_W = 600
let WIN_H = 400

// Куда Finder ставит иконки (top-left). Должно совпадать с build-dmg.sh.
let APP_X = 150.0, APP_Y = 205.0          // иконка приложения
let APPS_X = 450.0, APPS_Y = 205.0        // ярлык Applications

func render(scale: CGFloat, to path: String) {
    let w = Int(CGFloat(WIN_W) * scale)
    let h = Int(CGFloat(WIN_H) * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = ns
    ctx.scaleBy(x: scale, y: scale)

    let W = CGFloat(WIN_W), H = CGFloat(WIN_H)

    // Фон: мягкий вертикальный градиент.
    let grad = NSGradient(starting: NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1),
                          ending:   NSColor(calibratedRed: 0.85, green: 0.89, blue: 0.95, alpha: 1))!
    grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Координаты Finder — top-left, AppKit — bottom-left. Переводим Y.
    func fy(_ y: CGFloat) -> CGFloat { H - y }

    // Заголовок.
    let pc = NSMutableParagraphStyle(); pc.alignment = .center
    let titleAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.13, alpha: 1), .paragraphStyle: pc]
    ("WhitelistChecker" as NSString).draw(in: NSRect(x: 0, y: fy(64), width: W, height: 40),
                                          withAttributes: titleAttr)
    let subAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.40, alpha: 1), .paragraphStyle: pc]
    ("Диагностика сети по белым спискам · iOS · macOS" as NSString)
        .draw(in: NSRect(x: 0, y: fy(92), width: W, height: 20), withAttributes: subAttr)

    // Стрелка между иконками (на уровне их центров).
    let midY = fy((APP_Y + APPS_Y) / 2)
    let x0 = CGFloat(APP_X) + 78, x1 = CGFloat(APPS_X) - 78
    let line = NSBezierPath()
    line.lineWidth = 3
    line.lineCapStyle = .round
    line.move(to: NSPoint(x: x0, y: midY))
    line.line(to: NSPoint(x: x1 - 6, y: midY))
    NSColor(calibratedWhite: 0.45, alpha: 1).setStroke()
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: x1, y: midY))
    head.line(to: NSPoint(x: x1 - 14, y: midY + 9))
    head.line(to: NSPoint(x: x1 - 14, y: midY - 9))
    head.close()
    NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
    head.fill()

    // Подпись «Перетащите → в Applications» под стрелкой.
    let hintAttr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1), .paragraphStyle: pc]
    ("перетащите в Applications" as NSString)
        .draw(in: NSRect(x: 0, y: fy(160), width: W, height: 18), withAttributes: hintAttr)

    NSGraphicsContext.current = nil
    guard let cg = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = NSSize(width: WIN_W, height: WIN_H)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("✓ \(path)  (\(w)×\(h))")
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make-background.swift <out.png> [<out@2x.png>]"); exit(1) }
render(scale: 1, to: args[1])
if args.count >= 3 { render(scale: 2, to: args[2]) }
