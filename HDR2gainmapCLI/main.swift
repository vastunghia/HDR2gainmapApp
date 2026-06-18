import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - CLI Arguments Parser

struct CLIArguments {
    let inputPath: String
    let outputPath: String
    let verbose: Bool
    let verify: Bool
    let gainMapSubsample: Int?
    let auto: Bool
    let autoTolerancePercent: Double?
    let rgb: Bool           // emit a 3-channel (RGB) ISO 21496-1 gain map instead of luma
    let monoCoreImage: Bool // use the legacy Core Image mono gain map (PQ) instead of the default
                            // hand-assembled luma map (Display P3)
    let skipPreview: Bool   // experimental: skip generatePreview so the auto search runs cold (perf bench)
    let searchOnly: Bool    // experimental: run the auto search then exit before export (perf bench)

    static func parse() -> CLIArguments? {
        let args = CommandLine.arguments

        // Flags
        var verbose = false
        var verify = false
        var gainMapSubsample: Int? = nil
        var auto = false
        var autoTolerancePercent: Double? = nil
        var rgb = false
        var monoCoreImage = false
        var skipPreview = false
        var searchOnly = false
        var positionalArgs: [String] = []

        for arg in args.dropFirst() {
            if arg == "--verbose" || arg == "-v" {
                verbose = true
            } else if arg == "--verify" {
                verify = true
            } else if arg.hasPrefix("--gainmap-subsample=") {
                guard let v = Int(arg.dropFirst("--gainmap-subsample=".count)), v >= 1 else {
                    print("❌ Invalid value for --gainmap-subsample: \(arg) (must be an integer ≥ 1)")
                    return nil
                }
                gainMapSubsample = v
            } else if arg == "--auto" {
                auto = true
            } else if arg == "--rgb" {
                rgb = true
            } else if arg == "--mono-coreimage" {
                monoCoreImage = true
            } else if arg == "--skip-preview" {
                skipPreview = true
            } else if arg == "--search-only" {
                searchOnly = true
            } else if arg.hasPrefix("--auto-tolerance=") {
                guard let v = Double(arg.dropFirst("--auto-tolerance=".count)), v > 0, v <= 100 else {
                    print("❌ Invalid value for --auto-tolerance: \(arg) (must be a percentage in (0, 100])")
                    return nil
                }
                autoTolerancePercent = v
            } else if arg.hasPrefix("--") || arg.hasPrefix("-") {
                print("❌ Unknown flag: \(arg)")
                return nil
            } else {
                positionalArgs.append(arg)
            }
        }

        guard positionalArgs.count == 2 else {
            return nil
        }

        // --rgb and --mono-coreimage select mutually exclusive gain-map kinds.
        if rgb && monoCoreImage {
            print("❌ --rgb and --mono-coreimage are mutually exclusive (pick one gain-map kind)")
            return nil
        }

        return CLIArguments(
            inputPath: positionalArgs[0],
            outputPath: positionalArgs[1],
            verbose: verbose,
            verify: verify,
            gainMapSubsample: gainMapSubsample,
            auto: auto,
            autoTolerancePercent: autoTolerancePercent,
            rgb: rgb,
            monoCoreImage: monoCoreImage,
            skipPreview: skipPreview,
            searchOnly: searchOnly
        )
    }
    
    static func printUsage() {
        print("""
        Usage: HDR2gainmapCLI [OPTIONS] <input.png|tif> <output.heic>

        Arguments:
          <input>          Path to input HDR PNG or TIFF (PQ/HLG, 16-bit)
          <output.heic>    Path to output HEIC with gain map
        
        Options:
          -v, --verbose    Print detailed processing information
          --verify         Verify output file after export
          --gainmap-subsample=N  Gain map resolution divisor: 1 = full (default), 2 = half
          --auto           Auto-pick the source headroom: lowest value keeping the fraction of
                           pixels clipped in any single SDR channel within the tolerance
          --auto-tolerance=PCT   Per-channel clip tolerance for --auto, percent of pixels (default 1.0)
          --rgb            Emit a 3-channel (RGB) ISO 21496-1 gain map instead of luma (monochrome)
          --mono-coreimage Use the legacy Core Image mono gain map (tagged PQ) instead of the default
                           hand-assembled luma map (Display P3). Mutually exclusive with --rgb.

        Example:
          HDR2gainmapCLI input.png output.heic --verify
        """)
    }
}

// MARK: - Verification Function

func verifyExportedImage(at url: URL, verbose: Bool) -> Bool {
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        print("❌ Cannot open file for verification: \(url.path)")
        return false
    }
    
    // Check gain map — accept either the standard ISO 21496-1 slot or the legacy Apple slot.
    let hasISOGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        imageSource, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
    let hasAppleGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        imageSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil

    if hasISOGainMap {
        if verbose { print("✅ Gain map: FOUND (ISO 21496-1)") }
    } else if hasAppleGainMap {
        if verbose { print("✅ Gain map: FOUND (Apple HDRGainMap)") }
    } else {
        print("❌ Gain map: NOT FOUND")
    }

    // Check Apple maker tags — informational only. ISO output intentionally omits them.
    var hasMakerApple = false
    if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
       let makerApple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] {
        let maker33 = (makerApple["33"] as? NSNumber)?.floatValue
        let maker48 = (makerApple["48"] as? NSNumber)?.floatValue
        hasMakerApple = (maker33 != nil && maker48 != nil)
        if verbose {
            if hasMakerApple {
                print("ℹ️  MakerApple 33/48: present (legacy headroom encoding)")
                if let m33 = maker33 { print("   Tag 33: \(m33)") }
                if let m48 = maker48 { print("   Tag 48: \(m48)") }
            } else {
                print("ℹ️  MakerApple 33/48: absent (expected for ISO output)")
            }
        }
    } else if verbose {
        print("ℹ️  MakerApple 33/48: absent (expected for ISO output)")
    }

    // A file is valid if it carries a gain map under either scheme. The legacy Apple scheme
    // additionally relies on the maker tags, so require them in that case.
    let isValid = hasISOGainMap || (hasAppleGainMap && hasMakerApple)

    if verbose {
        print("\n📊 Verification Result: \(isValid ? "✅ VALID" : "❌ INVALID")")
    }

    return isValid
}

// MARK: - Main

@MainActor
func main() async {
    // Parse arguments
    guard let args = CLIArguments.parse() else {
        CLIArguments.printUsage()
        exit(1)
    }
    
    let inputURL = URL(fileURLWithPath: args.inputPath)
    let outputURL = URL(fileURLWithPath: args.outputPath)
    
    // Validate input
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
        print("❌ Input file not found: \(inputURL.path)")
        exit(1)
    }
    
    guard ["png", "tif", "tiff"].contains(inputURL.pathExtension.lowercased()) else {
        print("❌ Input must be a PNG or TIFF file")
        exit(1)
    }
    
    if args.verbose {
        print("🚀 HDR2gainmap CLI")
        print("   Input:  \(inputURL.path)")
        print("   Output: \(outputURL.path)")
        print()
    }
    
    // Create HDRImage and processor
    let image = HDRImage(url: inputURL, loadThumbnailImmediately: false)
    // The engine reads the gain map subsample factor from UserDefaults (shared with the GUI
    // preference). Default is 1 (full) when unset.
    if let gs = args.gainMapSubsample {
        UserDefaults.standard.set(gs, forKey: "gainMapSubsampleFactor")
    }
    // The engine reads the gain-map kind from UserDefaults. We set BOTH keys explicitly every run
    // (including the false case) — they live in the CLI's own argv0 UserDefaults domain, separate
    // from the GUI app's domain — so each invocation is deterministic regardless of residual state
    // left by a prior invocation on the same machine/runner. (The engine checks gainMapRGB first.)
    UserDefaults.standard.set(args.rgb, forKey: "gainMapRGB")
    UserDefaults.standard.set(args.monoCoreImage, forKey: "gainMapMonoCoreImage")
    let processor = HDRProcessor.shared

    if args.verbose {
        let kind = args.rgb ? "RGB (3-channel)"
            : (args.monoCoreImage ? "luma (Core Image, PQ)" : "luma (manual, Display P3)")
        print("   Gain map: \(kind)")
        let subsample = args.gainMapSubsample ?? 1
        print("   Gain map resolution: \(subsample <= 1 ? "full (1×)" : "1/\(subsample)×")")
    }
    
    do {
        // Validate HDR image
        if args.verbose {
            print("📊 Validating HDR image...")
        }
        
        if !args.skipPreview {
            let previewStart = Date()
            let _ = try await processor.generatePreview(for: image)
            let previewElapsed = Date().timeIntervalSince(previewStart)
            if args.verbose {
                print("⏱  generatePreview (decode + headroom + render): \(String(format: "%.3f", previewElapsed))s wall")
            }
        } else if args.verbose {
            print("⏭  generatePreview skipped (--skip-preview): auto search will run on a cold cache")
            // Isolate the cold headroom-scan cost. This warms getHeadroomForImage, so the auto
            // search that follows then measures loadHDR(cold) + renders only.
            let hrStart = Date()
            let hr = processor.getHeadroomForImage(url: inputURL)
            print("⏱  getHeadroomForImage (cold scan): \(String(format: "%.3f", Date().timeIntervalSince(hrStart)))s wall (headroom \(String(format: "%.2f", hr)))")
        }

        if args.verbose && !args.skipPreview {
            // Skipped under --skip-preview: this getHeadroomForImage call would warm the cache and
            // hide the cold decode+headroom cost we want the auto search to measure.
            let headroom = processor.getHeadroomForImage(url: inputURL)
            print("   Headroom: \(String(format: "%.2f", headroom)) (\(String(format: "%.2f", log2(headroom))) stops)")

            if let metadata = await image.loadMetadata() {
                print("   Resolution: \(metadata.width)×\(metadata.height)")
                print("   Color Space: \(metadata.colorSpace)")
                print("   Transfer: \(metadata.transferFunction)")
                print("   Bit Depth: \(metadata.bitDepth)-bit")
            }
            print()
        }
        
        // Auto tone-mapping: search the lowest source headroom within the clip tolerance and
        // feed it to the export via the Direct method (exact pass-through of the found value).
        if args.auto {
            let tolerance = (args.autoTolerancePercent ?? HDRProcessor.defaultAutoClipTolerancePercent) / 100.0
            let targetHeadroom = image.settings.targetHeadroom ?? 1.0
            let autoStart = Date()
            let result = try await processor.findAutoSourceHeadroom(
                url: inputURL,
                targetHeadroom: targetHeadroom,
                tolerance: tolerance
            )
            let autoElapsed = Date().timeIntervalSince(autoStart)
            image.settings.sourceHeadroomMethod = .direct
            image.settings.directSourceHeadroom = result.sourceHeadroom
            if args.verbose {
                print("🎯 Auto source headroom: \(String(format: "%.3f", result.sourceHeadroom)) " +
                      "(measured \(String(format: "%.3f", result.measuredHeadroom)), " +
                      "max per-channel clip \(String(format: "%.4f", result.clipFraction * 100))%, " +
                      "\(result.iterations) evaluations)")
                print("⏱  Auto search: \(String(format: "%.3f", autoElapsed))s wall " +
                      "(\(String(format: "%.1f", autoElapsed / Double(max(1, result.iterations)) * 1000)) ms/eval)")
                if !result.metTolerance {
                    print("⚠️  Tolerance not reachable even at the measured headroom; using the measured value")
                }
                print()
            }
        }

        if args.searchOnly {
            exit(0)  // perf bench: stop before export
        }

        // Export
        if args.verbose {
            print("🔄 Exporting to HEIC with gain map...")
        }
        
        let exportStart = Date()
        try await processor.exportImage(image, to: outputURL)
        if args.verbose {
            print("⏱  exportImage (encode + ISO + write): \(String(format: "%.3f", Date().timeIntervalSince(exportStart)))s wall")
        }

        print("✅ Export successful: \(outputURL.path)")
        
        // Verify if requested
        if args.verify {
            if args.verbose {
                print("\n🔍 Verifying exported file...")
            }
            
            let isValid = verifyExportedImage(at: outputURL, verbose: args.verbose)
            
            if !isValid {
                print("\n⚠️  Warning: Exported file may have issues")
                exit(2)  // Exit code 2 = export succeeded but verification failed
            } else {
                print("✅ Verification passed")
            }
        }
        
        exit(0)
        
    } catch {
        print("❌ Export failed: \(error.localizedDescription)")
        if args.verbose {
            print("\nError details: \(error)")
        }
        exit(1)
    }
}

// MARK: - Batch parallelism benchmark (experimental)

/// Headless harness to measure the auto-tune throughput of a folder of inputs at a chosen
/// concurrency. Runs only the auto-tune work (`findAutoSourceHeadroom`) — no export — which is
/// exactly the per-image cost of the GUI "Auto all" batch. Usage:
///   HDR2gainmapCLI --bench --bench-dir=<folder> [--concurrency=N] [--auto-tolerance=PCT]
@MainActor
func runBenchmark() async {
    let argv = CommandLine.arguments
    var dir: String? = nil
    var concurrency = HDRProcessor.defaultAutoConcurrency()
    var tolerancePct = HDRProcessor.defaultAutoClipTolerancePercent
    for a in argv {
        if a.hasPrefix("--bench-dir=") { dir = String(a.dropFirst("--bench-dir=".count)) }
        else if a.hasPrefix("--concurrency=") { concurrency = max(1, Int(a.dropFirst("--concurrency=".count)) ?? 1) }
        else if a.hasPrefix("--auto-tolerance=") { tolerancePct = Double(a.dropFirst("--auto-tolerance=".count)) ?? tolerancePct }
    }
    guard let dir else {
        print("❌ --bench requires --bench-dir=<folder>")
        exit(1)
    }
    let folder = URL(fileURLWithPath: dir, isDirectory: true)
    let exts: Set<String> = ["png", "tif", "tiff"]
    let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
        .filter { exts.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !urls.isEmpty else {
        print("❌ No png/tif/tiff files in \(folder.path)")
        exit(1)
    }

    let tol = tolerancePct / 100.0
    let processor = HDRProcessor.shared
    print("🏁 Benchmark: \(urls.count) images, concurrency=\(concurrency) " +
          "(physical cores=\(HDRProcessor.physicalCoreCount()), auto=\(HDRProcessor.defaultAutoConcurrency())), " +
          "tolerance=\(tolerancePct)%")

    final class FailBox: @unchecked Sendable { var n = 0 }
    let fails = FailBox()
    let jobs = urls.map { (url: $0, targetHeadroom: Float(1.0)) }

    let verifySH = argv.contains("--bench-print-sh")
    let start = Date()
    await processor.autoSearchBatch(jobs: jobs, tolerance: tol, concurrency: concurrency) { index, url, result in
        switch result {
        case .failure: fails.n += 1
        case .success(let r):
            if verifySH {
                print(String(format: "   [%02d] %@  sH=%.3f (clip %.4f%%)",
                             index, url.lastPathComponent, r.sourceHeadroom, r.clipFraction * 100))
            }
        }
    }
    let elapsed = Date().timeIntervalSince(start)
    let n = Double(urls.count)
    print(String(format: "⏱  Total: %.2fs | %.3fs/img | %.2f img/s | failures: %d",
                 elapsed, elapsed / n, n / elapsed, fails.n))
    exit(0)
}

// Start async main
Task { @MainActor in
    if CommandLine.arguments.contains("--bench") {
        await runBenchmark()
    } else {
        await main()
    }
}

// Keep the process running
RunLoop.main.run()
