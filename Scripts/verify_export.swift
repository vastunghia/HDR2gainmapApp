#!/usr/bin/env swift

import Foundation
import ImageIO
import CoreGraphics

func verifyHEICFile(at path: String) -> (hasGainMap: Bool, hasMakerApple: Bool, details: String) {
    guard let url = URL(string: "file://\(path)"),
          let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return (false, false, "❌ Cannot open file: \(path)")
    }
    
    var details = ""
    var hasGainMap = false
    
    // === DEBUG: Elenca TUTTE le auxiliary data types disponibili ===
    details += "\n🔍 AUXILIARY DATA EXPLORATION:\n"
    
    // Lista di possibili chiavi gain map note
    let knownGainMapKeys: [CFString] = [
        kCGImageAuxiliaryDataTypeHDRGainMap,
        "HDRGainMap" as CFString,
        "urn:com:apple:photo:2020:aux:hdrgainmap" as CFString,
        "public.auxiliary-data.hdrgainmap" as CFString,
    ]
    
    for key in knownGainMapKeys {
        if let auxData = CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, key) {
            hasGainMap = true
            let keyStr = key as String
            details += "   ✅ Found auxiliary data with key: \(keyStr)\n"
            
            if let auxDict = auxData as? [String: Any] {
                details += "      Properties: \(auxDict.keys.joined(separator: ", "))\n"
            }
        }
    }
    
    // Prova anche a enumerare TUTTE le auxiliary data (non documentato ma proviamo)
    if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
        if let auxDataInfo = properties["{Auxiliary}" as String] as? [String: Any] {
            details += "\n   📦 Raw {Auxiliary} dictionary:\n"
            for (key, value) in auxDataInfo {
                details += "      - \(key): \(type(of: value))\n"
            }
        }
        
        // Cerca anche altre chiavi che potrebbero contenere gain map
        for (key, _) in properties {
            if key.lowercased().contains("gain") || key.lowercased().contains("hdr") {
                details += "   🔎 Found HDR-related property: \(key)\n"
            }
        }
    }
    
    if !hasGainMap {
        details += "   ❌ No gain map found with any known key\n"
    }
    
    // === Check Apple metadata (come prima) ===
    var hasMakerApple = false
    var maker33: Float? = nil
    var maker48: Float? = nil
    
    if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
        
        details += "\n📐 Resolution: "
        if let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
           let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
            details += "\(width)×\(height)\n"
        } else {
            details += "Unknown\n"
        }
        
        details += "🎨 Color Space: "
        if let colorSpace = properties[kCGImagePropertyProfileName as String] as? String {
            details += "\(colorSpace)\n"
        } else {
            details += "Unknown\n"
        }
        
        if let makerApple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] {
            details += "\n✅ MakerApple Dictionary: FOUND\n"
            
            if let m33 = makerApple["33"] as? NSNumber {
                maker33 = m33.floatValue
                details += "   Tag 33: \(maker33!)\n"
            } else {
                details += "   Tag 33: MISSING\n"
            }
            
            if let m48 = makerApple["48"] as? NSNumber {
                maker48 = m48.floatValue
                details += "   Tag 48: \(maker48!)\n"
            } else {
                details += "   Tag 48: MISSING\n"
            }
            
            hasMakerApple = (maker33 != nil && maker48 != nil)
            
            if makerApple.count > 2 {
                let otherKeys = makerApple.keys.filter { $0 != "33" && $0 != "48" }
                if !otherKeys.isEmpty {
                    details += "   Other tags: \(otherKeys.sorted().joined(separator: ", "))\n"
                }
            }
        } else {
            details += "\n❌ MakerApple Dictionary: NOT FOUND\n"
        }
    }
    
    return (hasGainMap, hasMakerApple, details)
}

// Main
guard CommandLine.arguments.count > 1 else {
    print("Usage: verify_export.swift <path-to-heic>")
    exit(1)
}

let filePath = CommandLine.arguments[1]
let expandedPath = NSString(string: filePath).expandingTildeInPath

let (hasGainMap, hasMakerApple, details) = verifyHEICFile(at: expandedPath)

print("\n" + String(repeating: "=", count: 70))
print("VERIFICATION REPORT")
print(String(repeating: "=", count: 70))
print("File: \(expandedPath)\n")
print(details)
print(String(repeating: "=", count: 70))
print("\n📊 SUMMARY:")
print("   Gain Map:        \(hasGainMap ? "✅ PRESENT" : "❌ MISSING")")
print("   Apple Metadata:  \(hasMakerApple ? "✅ PRESENT" : "❌ MISSING")")
print("   Overall Result:  \(hasGainMap && hasMakerApple ? "✅ VALID" : "❌ INVALID")")
print(String(repeating: "=", count: 70) + "\n")

exit(hasGainMap && hasMakerApple ? 0 : 1)
