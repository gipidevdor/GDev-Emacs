// Copyright (C) 2026 Giacomo Picchiarelli
// SPDX-License-Identifier: GPL-3.0-or-later

// Dialogo di stampa nativo per GDev-Emacs.  Legge dal file indicato come
// quarto argomento, o da stdin, il documento composto da lisp/gdev-print.el:
// {"font": famiglia, "tab": colonne,
// "runs": [[testo, primo piano, sfondo, stile], ...]}, con i colori in
// #RRGGBB già adattati alla carta e lo stile come somma di 1 grassetto,
// 2 corsivo, 4 sottolineato, 8 barrato.

import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(EXIT_FAILURE)
}

// Con un quarto argomento il documento si legge dal file indicato: Emacs non
// aspetta che Swift abbia compilato lo script per consegnarlo.
let data: Data
if CommandLine.arguments.indices.contains(3) {
    guard let contents = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])) else {
        fail("Il documento da stampare non si può leggere.")
    }
    data = contents
} else {
    data = FileHandle.standardInput.readDataToEndOfFile()
}
guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let runs = document["runs"] as? [[Any]] else {
    fail("Il documento da stampare non è leggibile.")
}

let app = NSApplication.shared
ProcessInfo.processInfo.processName = "GDev-Emacs"
app.setActivationPolicy(.regular)
if CommandLine.arguments.indices.contains(2),
   let icon = NSImage(contentsOfFile: CommandLine.arguments[2]), icon.isValid {
    NSImage(named: NSImage.applicationIconName)?.setName(nil)
    icon.setName(NSImage.applicationIconName)
    app.applicationIconImage = icon
}
app.finishLaunching()
app.activate(ignoringOtherApps: true)

let info = NSPrintInfo.shared.copy() as! NSPrintInfo
info.topMargin = 36
info.bottomMargin = 36
info.leftMargin = 36
info.rightMargin = 36
info.horizontalPagination = .fit
info.verticalPagination = .automatic
info.isHorizontallyCentered = false
info.isVerticallyCentered = false

// Il carattere dell'editor, se macOS lo conosce per famiglia; altrimenti
// quello a spaziatura fissa di sistema.
let size: CGFloat = 10
let fonts = NSFontManager.shared
let base = (document["font"] as? String).flatMap {
    fonts.font(withFamily: $0, traits: [], weight: 5, size: size)
} ?? .monospacedSystemFont(ofSize: size, weight: .regular)
var variants: [Int: NSFont] = [:]
func font(_ style: Int) -> NSFont {
    if let cached = variants[style & 3] { return cached }
    var result = base
    if style & 1 != 0 { result = fonts.convert(result, toHaveTrait: .boldFontMask) }
    if style & 2 != 0 { result = fonts.convert(result, toHaveTrait: .italicFontMask) }
    variants[style & 3] = result
    return result
}

func color(_ value: Any) -> NSColor? {
    guard let hex = value as? String, hex.count == 7, hex.hasPrefix("#"),
          let rgb = Int(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
                   green: CGFloat((rgb >> 8) & 0xff) / 255,
                   blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
}

// Le tabulazioni cadono ogni `tab` colonne, come nell'editor.
let paragraph = NSMutableParagraphStyle()
let advance = ("0" as NSString).size(withAttributes: [.font: base]).width
paragraph.tabStops = []
paragraph.defaultTabInterval = advance * CGFloat(max(1, document["tab"] as? Int ?? 8))

let text = NSMutableAttributedString()
for run in runs {
    guard run.count >= 4, let string = run[0] as? String else { continue }
    let style = run[3] as? Int ?? 0
    var attributes: [NSAttributedString.Key: Any] = [
        .font: font(style),
        .foregroundColor: color(run[1]) ?? NSColor.black,
        .paragraphStyle: paragraph,
    ]
    if let background = color(run[2]) { attributes[.backgroundColor] = background }
    if style & 4 != 0 { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    if style & 8 != 0 { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
    text.append(NSAttributedString(string: string, attributes: attributes))
}

let width = info.paperSize.width - info.leftMargin - info.rightMargin
let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
// La carta è sempre chiara, anche con l'aspetto scuro di macOS.
view.appearance = NSAppearance(named: .aqua)
view.isVerticallyResizable = true
view.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
view.textContainer?.widthTracksTextView = true
view.drawsBackground = true
view.backgroundColor = .white
view.textStorage?.setAttributedString(text)
if let container = view.textContainer, let layout = view.layoutManager {
    layout.ensureLayout(for: container)
    let lineHeight = layout.defaultLineHeight(for: base)
    let height = max(lineHeight, ceil(layout.usedRect(for: container).maxY))
    view.setFrameSize(NSSize(width: width, height: height))
}

let operation = NSPrintOperation(view: view, printInfo: info)
operation.jobTitle = CommandLine.arguments.dropFirst().first ?? "GDev-Emacs"
operation.showsPrintPanel = true
operation.showsProgressPanel = true
operation.printPanel.options.insert(.showsPreview)
// Annullare il dialogo è un esito normale.
_ = operation.run()
