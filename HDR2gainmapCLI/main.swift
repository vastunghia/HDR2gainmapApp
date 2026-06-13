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

    static func parse() -> CLIArguments? {
        let args = CommandLine.arguments

        // Flags
        var verbose = false
        var verify = false
        var gainMapSubsample: Int? = nil
        var auto = false
        var autoTolerancePercent: Double? = nil
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

        return CLIArguments(
            inputPath: positionalArgs[0],
            outputPath: positionalArgs[1],
            verbose: verbose,
            verify: verify,
            gainMapSubsample: gainMapSubsample,
            auto: auto,
            autoTolerancePercent: autoTolerancePercent
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
          --gainmap-subsample=N  Gain map resolution divisor: 1 = full, 2 = half (default)
          --auto           Auto-pick the source headroom: lowest value keeping the fraction of
                           pixels clipped in any single SDR channel within the tolerance
          --auto-tolerance=PCT   Per-channel clip tolerance for --auto, percent of pixels (default 1.0)

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
    // preference). Default is 2 (half) when unset.
    if let gs = args.gainMapSubsample {
        UserDefaults.standard.set(gs, forKey: "gainMapSubsampleFactor")
    }
    let processor = HDRProcessor.shared

    if args.verbose {
        print("   Gain map: luma (monochrome)")
        let subsample = args.gainMapSubsample ?? 2
        print("   Gain map resolution: \(subsample <= 1 ? "full (1×)" : "1/\(subsample)×")")
    }
    
    do {
        // Validate HDR image
        if args.verbose {
            print("📊 Validating HDR image...")
        }
        
        let _ = try await processor.generatePreview(for: image)
        
        if args.verbose {
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
            let result = try await processor.findAutoSourceHeadroom(
                url: inputURL,
                targetHeadroom: targetHeadroom,
                tolerance: tolerance
            )
            image.settings.sourceHeadroomMethod = .direct
            image.settings.directSourceHeadroom = result.sourceHeadroom
            if args.verbose {
                print("🎯 Auto source headroom: \(String(format: "%.3f", result.sourceHeadroom)) " +
                      "(measured \(String(format: "%.3f", result.measuredHeadroom)), " +
                      "max per-channel clip \(String(format: "%.4f", result.clipFraction * 100))%, " +
                      "\(result.iterations) evaluations)")
                if !result.metTolerance {
                    print("⚠️  Tolerance not reachable even at the measured headroom; using the measured value")
                }
                print()
            }
        }

        // Export
        if args.verbose {
            print("🔄 Exporting to HEIC with gain map...")
        }
        
        try await processor.exportImage(image, to: outputURL)
        
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

// Start async main
Task { @MainActor in
    await main()
}

// Keep the process running
RunLoop.main.run()
