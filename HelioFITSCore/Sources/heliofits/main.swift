// heliofits: the HelioFITSCore renderer from the command line, for scripts and SSH sessions.
// Built from source only (swift build -c release --package-path HelioFITSCore); not shipped in
// the App Store app or the GitHub zip. No network calls.
// Exit status: 0 success, 1 runtime error (message on stderr), 2 usage error.

import Foundation
import HelioFITSCore

let usage = """
usage: heliofits --header <file>
       heliofits --export <file> [--hdu N] [--plane N] [--max-side N] --out <png>
       heliofits --info <file> [--hdu N] [--plane N]
  --hdu N       image HDU; -1 (default) is the first image HDU, -2 the last
  --plane N     0-based plane of a data cube (default 0)
  --max-side N  longest side of the exported PNG in pixels (default 2048)
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func usageError(_ why: String) -> Never {
    fail("heliofits: \(why)\n" + usage, code: 2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { usageError("no command given") }
args.removeFirst()
guard let file = args.first, !file.hasPrefix("--") else { usageError("\(verb) needs a file") }
args.removeFirst()

var options: [String: String] = [:]
while let flag = args.first {
    args.removeFirst()
    guard ["--hdu", "--plane", "--max-side", "--out"].contains(flag) else { usageError("unknown option \(flag)") }
    guard let value = args.first else { usageError("\(flag) needs a value") }
    args.removeFirst()
    options[flag] = value
}

func intOption(_ flag: String, _ fallback: Int) -> Int {
    guard let s = options[flag] else { return fallback }
    guard let v = Int(s) else { usageError("\(flag) needs an integer, got \(s)") }
    return v
}

/// The first HDU with image planes, walking HDUs until one does not exist. Done
/// here, through the core's own calls, so the CLI never reads the app-group default.
func firstImageHDU(_ path: String) -> Int? {
    var h = 0
    while h < FITSRenderer.maxPagerHDUs, FITSRenderer.cards(path: path, hdu: h) != nil {
        if FITSRenderer.planeCount(path: path, hdu: h) > 0 { return h }
        h += 1
    }
    return nil
}

/// Always an explicit HDU: -1 becomes the first image HDU, -2 the last.
func resolvedHDU(_ path: String) -> Int {
    let want = intOption("--hdu", -1)
    guard want == -1 else { return FITSRenderer.resolveAutoHDU(path: path, want: want) }
    guard let h = firstImageHDU(path) else { fail("heliofits: no image HDU in \(path)", code: 1) }
    return h
}

guard FileManager.default.fileExists(atPath: file) else { fail("heliofits: no such file: \(file)", code: 1) }

switch verb {
case "--header":
    guard options.isEmpty else { usageError("--header takes no options") }
    print(FITSHeader.dump(path: file), terminator: "")

case "--export":
    guard let out = options["--out"] else { usageError("--export needs --out <png>") }
    let maxSide = intOption("--max-side", 2048)
    guard maxSide > 0 else { usageError("--max-side must be positive") }
    let plane = intOption("--plane", 0)
    let hdu = resolvedHDU(file)
    do {
        let r = try FITSRenderer.render(path: file, maxSide: maxSide, hdu: hdu, plane: plane)
        try r.pngData().write(to: URL(fileURLWithPath: out))
        print("wrote \(out) (\(r.width)x\(r.height), hdu \(hdu))")
    } catch {
        fail("heliofits: \(error.localizedDescription)", code: 1)
    }

case "--info":
    guard options["--out"] == nil, options["--max-side"] == nil else { usageError("--info takes only --hdu and --plane") }
    let plane = intOption("--plane", 0)
    let hdu = resolvedHDU(file)
    do {
        let r = try FITSRenderer.render(path: file, maxSide: FITSRenderer.maxSide, hdu: hdu, plane: plane)
        let wcs = FITSRenderer.solarWCS(cards: FITSRenderer.cards(path: file, hdu: hdu) ?? "", isSolar: r.cmapKey != nil)
        print("file      \((file as NSString).lastPathComponent)")
        print("hdu       \(hdu)")
        print("plane     \(plane)")
        print("size      \(r.natW)x\(r.natH)")
        print("colormap  \(r.cmapKey ?? "grey")")
        print("clip      \(FITSRenderer.fmtValue(r.lo)) \(FITSRenderer.fmtValue(r.hi))")
        print("gamma     \(r.gam)")
        print("solar_wcs \(wcs == nil ? "no" : "yes")")
    } catch {
        fail("heliofits: \(error.localizedDescription)", code: 1)
    }

default:
    usageError("unknown command \(verb)")
}
