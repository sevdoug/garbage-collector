// Gera o ícone do app (um treemap estilizado). Uso: scripts/make-icon.sh
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments[1]

guard
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { fatalError("não foi possível criar o bitmap") }

NSGraphicsContext.current = context

// Base no formato padrão de ícone do macOS (quadrado arredondado com margem).
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
NSGradient(colors: [
    NSColor(calibratedWhite: 0.20, alpha: 1),
    NSColor(calibratedWhite: 0.10, alpha: 1),
])!.draw(in: platePath, angle: -90)

// Blocos em frações da área útil: (x, y, largura, altura, matiz, brilho).
let tiles: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (0.00, 0.42, 0.58, 0.58, 0.59, 0.86),
    (0.60, 0.62, 0.40, 0.38, 0.47, 0.84),
    (0.60, 0.42, 0.19, 0.18, 0.47, 0.72),
    (0.81, 0.42, 0.19, 0.18, 0.36, 0.84),
    (0.00, 0.00, 0.36, 0.40, 0.14, 0.92),
    (0.38, 0.18, 0.30, 0.22, 0.07, 0.92),
    (0.38, 0.00, 0.30, 0.16, 0.98, 0.86),
    (0.70, 0.00, 0.30, 0.40, 0.80, 0.80),
]

let area = plate.insetBy(dx: 96, dy: 96)
for (x, y, width, height, hue, brightness) in tiles {
    let rect = NSRect(
        x: area.minX + x * area.width,
        y: area.minY + y * area.height,
        width: width * area.width,
        height: height * area.height
    )
    NSColor(calibratedHue: hue, saturation: 0.55, brightness: brightness, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22).fill()
}

context.flushGraphics()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
