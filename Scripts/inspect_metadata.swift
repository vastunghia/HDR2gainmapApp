#!/usr/bin/env swift

import Foundation
import ImageIO
import CoreGraphics

func inspectAllMetadata(at path: String) {
    let expandedPath = NSString(string: path).expandingTildeInPath
    let url = URL(fileURLWithPath: expandedPath)
    
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        print("❌ Cannot open file: \(path)")
        exit(1)
    }
    
    guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
        print("❌ Cannot read properties")
        exit(1)
    }
    
    print("\n" + String(repeating: "=", count: 70))
    print("METADATA INSPECTION REPORT")
    print(String(repeating: "=", count: 70))
    print("File: \(expandedPath)\n")
    
    // Stampa TUTTE le chiavi top-level
    print("📋 TOP-LEVEL KEYS (\(properties.keys.count) total):\n")
    
    for key in properties.keys.sorted() {
        let value = properties[key]!
        let valueType = type(of: value)
        
        if let dict = value as? [String: Any] {
            print("  ✅ \(key) → Dictionary with \(dict.keys.count) entries")
            print("     Sub-keys: \(dict.keys.sorted().prefix(5).joined(separator: ", "))\(dict.keys.count > 5 ? "..." : "")")
        } else if let array = value as? [Any] {
            print("  📦 \(key) → Array with \(array.count) elements")
        } else {
            print("  📌 \(key) → \(valueType): \(value)")
        }
    }
    
    // Dizionari comuni da espandere completamente
    let importantDicts: [String] = [
        kCGImagePropertyExifDictionary as String,
        kCGImagePropertyIPTCDictionary as String,
        kCGImagePropertyTIFFDictionary as String,
        kCGImagePropertyGPSDictionary as String,
        kCGImagePropertyPNGDictionary as String,
        kCGImagePropertyMakerAppleDictionary as String,
    ]
    
    for dictKey in importantDicts {
        if let dict = properties[dictKey] as? [String: Any], !dict.isEmpty {
            print("\n" + String(repeating: "-", count: 70))
            print("📖 DETAILED: \(dictKey) (\(dict.keys.count) entries)")
            print(String(repeating: "-", count: 70))
            
            for key in dict.keys.sorted() {
                let value = dict[key]!
                let valueType = type(of: value)
                
                // Formatta il valore in modo leggibile
                var displayValue = "\(value)"
                if displayValue.count > 60 {
                    displayValue = String(displayValue.prefix(60)) + "..."
                }
                
                print("   \(key)")
                print("      Type: \(valueType)")
                print("      Value: \(displayValue)")
            }
        }
    }
    
    print("\n" + String(repeating: "=", count: 70))
    print("\n✅ Inspection complete\n")
    
    // Genera lista Swift per copia-incolla
    print("📝 SWIFT CODE SNIPPET (copy-paste ready):")
    print("\nlet keysToPreserve: [CFString] = [")
    for key in properties.keys.sorted() {
        // Skippa chiavi PNG-specific e quelle che cambieranno
        let skipKeys = ["PNG", "PixelWidth", "PixelHeight", "Depth", "ColorModel", "ProfileName"]
        if !skipKeys.contains(where: { key.contains($0) }) {
            print("    \"\(key)\" as CFString,")
        }
    }
    print("]\n")
}

// Main
guard CommandLine.arguments.count > 1 else {
    print("Usage: inspect_metadata.swift <path-to-image>")
    exit(1)
}

let filePath = CommandLine.arguments[1]
inspectAllMetadata(at: filePath)
