import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - CLI Arguments Parser

struct CLIArguments {
    let inputPath: String
    let outputPath: String
    let verbose: Bool
    let verify: Bool
    
    static func parse() -> CLIArguments? {
        let args = CommandLine.arguments
        
        // Flags
        var verbose = false
        var verify = false
        var positionalArgs: [String] = []
        
        for arg in args.dropFirst() {
            if arg == "--verbose" || arg == "-v" {
                verbose = true
            } else if arg == "--verify" {
                verify = true
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
            verify: verify
        )
    }
    
    static func printUsage() {
        print("""
        Usage: HDR2gainmapCLI [OPTIONS] <input.png> <output.heic>
        
        Arguments:
          <input.png>      Path to input HDR PNG (Display P3 PQ, 16-bit)
          <output.heic>    Path to output HEIC with gain map
        
        Options:
          -v, --verbose    Print detailed processing information
          --verify         Verify output file after export
        
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
    
    // Check gain map
    var hasGainMap = false
    if let _ = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
        imageSource, 0, kCGImageAuxiliaryDataTypeHDRGainMap as CFString
    ) {
        hasGainMap = true
        if verbose {
            print("✅ Gain map: FOUND")
        }
    } else {
        print("❌ Gain map: NOT FOUND")
    }
    
    // Check Apple metadata
    var hasMakerApple = false
    var maker33: Float? = nil
    var maker48: Float? = nil
    
    if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
       let makerApple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] {
        
        if let m33 = makerApple["33"] as? NSNumber {
            maker33 = m33.floatValue
        }
        if let m48 = makerApple["48"] as? NSNumber {
            maker48 = m48.floatValue
        }
        
        hasMakerApple = (maker33 != nil && maker48 != nil)
        
        if verbose {
            print("✅ MakerApple Dictionary: FOUND")
            if let m33 = maker33, let m48 = maker48 {
                print("   Tag 33: \(m33)")
                print("   Tag 48: \(m48)")
            }
        }
    } else {
        print("❌ MakerApple Dictionary: NOT FOUND")
    }
    
    let isValid = hasGainMap && hasMakerApple
    
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
    
    guard inputURL.pathExtension.lowercased() == "png" else {
        print("❌ Input must be a PNG file")
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
    let processor = HDRProcessor.shared
    
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
