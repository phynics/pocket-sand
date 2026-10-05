// Read a screenshot the way a person does, and check what it says.
//
//   swift scripts/visual-assert.swift <png> <expectations.json> <screen>
//
// Why not compare pixels: a system font update, a different simulator runtime or a
// minute change in anti-aliasing moves every pixel and means nothing. What matters is
// *what the screen says* — that a label is there, that its answer is complete, and that
// nothing was truncated to fit. Vision reads the screen, so the assertions can be about
// the reading rather than about the rendering.
//
// The two general rules at the bottom are the ones that caught real defects: a line
// ending in an ellipsis is text that did not fit, and a line ending in a hyphen is a
// word the layout broke in half. Both are properties of the whole screen, so they need
// no expectations to be written for them.
//
//   swift scripts/visual-assert.swift shot.png scripts/visual-expectations.json newtask
//
// The key is usually the screen, and may carry the text size — `newtask@accessibility-
// extra-extra-large` — because what is on screen at the largest size is not what is on
// screen at the default one.

import AppKit
import Foundation
import Vision

/// One line of recognised text, and where it was.
struct Line {
    let text: String
    /// Normalised, origin bottom-left, as Vision reports it.
    let box: CGRect
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("visual-assert: \(message)\n".utf8))
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: visual-assert <png> <expectations.json> <screen>")
}
let imageURL = URL(fileURLWithPath: arguments[1])
let expectationsURL = URL(fileURLWithPath: arguments[2])
let key = arguments[3]

guard let image = NSImage(contentsOf: imageURL),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fail("cannot read \(imageURL.path)") }

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
// The app is mostly small type at the edges of a phone screen; without this, thin
// light-mode grey is read as nothing at all.
request.usesLanguageCorrection = false
try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

let lines: [Line] = (request.results ?? []).compactMap { observation in
    guard let candidate = observation.topCandidates(1).first else { return nil }
    return Line(text: candidate.string, box: observation.boundingBox)
}
let readAll = lines.map(\.text).joined(separator: "\n")
// Whitespace is the scanner's business, not the screen's: it may split or join runs.
let readFlattened = readAll
    .replacingOccurrences(of: "\n", with: " ")
    .replacingOccurrences(of: "  ", with: " ")

guard let data = try? Data(contentsOf: expectationsURL),
      let expectations = try? JSONDecoder().decode([String: [String]].self, from: data)
else { fail("cannot read \(expectationsURL.path)") }

var failures: [String] = []

// 1. Everything this screen is supposed to say, said in full. A substring and not an
//    equality: the scanner may group a label and its answer onto one line, and that is
//    a fact about the scanner.
// Exact match, no fallback: a size-specific entry lists what is *visible at that size*,
// and falling back to the screen's full list would demand text that is off screen.
for expected in expectations[key] ?? [] {
    if !readFlattened.contains(expected) {
        failures.append("missing or truncated: “\(expected)”")
    }
}

// 2. Nothing was cut to fit. An ellipsis on screen means a word did not fit, and the
//    accessibility text sizes are where that happens — but a few are deliberate, and the
//    expectations file names them under `_expectedTruncation`. The connect screen's
//    token placeholder is one: `kandev_pat_…` stands for a credential nobody should be
//    shown the shape of, so it is *meant* to be cut. It is matched by prefix, because
//    the scanner renders an ellipsis as one character or three depending on the mood.
let expectedTruncation = expectations["_expectedTruncation"] ?? []
for line in lines where line.text.hasSuffix("…") || line.text.range(of: #"\.\.+$"#, options: .regularExpression) != nil {
    let isExpected = expectedTruncation.contains { allowed in
        line.text.hasPrefix(allowed.replacingOccurrences(of: "…", with: ""))
    }
    if !isExpected {
        failures.append("truncated text: “\(line.text)”")
    }
}

// 3. No word was broken in half. A hyphen at the end of a line is the layout admitting
//    it had nowhere to put the word — "Set-" above "up".
for line in lines where line.text.hasSuffix("-") {
    failures.append("word broken across lines: “\(line.text)”")
}

if failures.isEmpty {
    print("ok    \(key)")
    exit(0)
}

for failure in failures {
    print("FAIL  \(key): \(failure)")
}
exit(1)
