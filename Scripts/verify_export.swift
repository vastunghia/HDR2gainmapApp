#!/usr/bin/env swift

import Foundation
import CoreFoundation
import ImageIO
import CoreGraphics

func cfTypeDescription(_ any: Any) -> String {
    let cf = any as CFTypeRef
    let tid = CFGetTypeID(cf)
    return (CFCopyTypeIDDescription(tid) as String?) ?? "Unknown CFTypeID=\(tid)"
}

func verifyHEICFile(at path: String) -> (hasGainMap: Bool, hasMakerApple: Bool, details: String) {
    
    let expandedPath = NSString(string: path).expandingTildeInPath
    let url = URL(fileURLWithPath: expandedPath)  // ✅ Gestisce automaticamente path relativi
    
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return (false, false, "❌ Cannot open file: \(path)")
    }
    
    var details = ""
    var hasGainMap = false
    var hasAppleGainMap = false
    var hasISOGainMap = false
    
    // === DEBUG: Elenca TUTTE le auxiliary data types disponibili ===
    details += "\n🔍 AUXILIARY DATA EXPLORATION:\n"
    
    // Lista di possibili chiavi gain map note
    let knownGainMapKeys: [CFString] = [
        kCGImageAuxiliaryDataTypeHDRGainMap,
        kCGImageAuxiliaryDataTypeISOGainMap,
        "HDRGainMap" as CFString,
        "urn:com:apple:photo:2020:aux:hdrgainmap" as CFString,
        "public.auxiliary-data.hdrgainmap" as CFString,
    ]
    
    for key in knownGainMapKeys {
        guard let auxData = CGImageSourceCopyAuxiliaryDataInfoAtIndex(imageSource, 0, key) else {
            continue
        }

        hasGainMap = true
        let keyStr = key as String
        details += "   ✅ Found auxiliary data with key: \(keyStr)\n"

        if key == kCGImageAuxiliaryDataTypeHDRGainMap { hasAppleGainMap = true }
        if key == kCGImageAuxiliaryDataTypeISOGainMap { hasISOGainMap = true }

        guard let auxDict = auxData as? [String: Any] else {
            details += "      ⚠️ Auxiliary data is not a [String:Any] dictionary\n"
            continue
        }

        details += "      Properties: \(auxDict.keys.sorted().joined(separator: ", "))\n"

        // 1) Stampa DataDescription (se presente)
        if let desc = auxDict[kCGImageAuxiliaryDataInfoDataDescription as String] {
            details += "      DataDescription: \(desc)\n"
        }

        // 2) Prova a decodificare il payload come immagine (se presente)
        if let data = auxDict[kCGImageAuxiliaryDataInfoData as String] as? Data {
            details += "      Data bytes: \(data.count)\n"

            if let gmSrc = CGImageSourceCreateWithData(data as CFData, nil),
               let gmProps = CGImageSourceCopyPropertiesAtIndex(gmSrc, 0, nil) as? [String: Any] {

                let w = gmProps[kCGImagePropertyPixelWidth as String] ?? "?"
                let h = gmProps[kCGImagePropertyPixelHeight as String] ?? "?"
                details += "      Payload decodes as image: ✅ (\(w)x\(h))\n"
            } else {
                details += "      Payload decodes as image: ❌ (cannot decode)\n"
            }
        } else {
            details += "      ⚠️ No kCGImageAuxiliaryDataInfoData payload found\n"
        }
        
        // Prova entrambe le possibili chiavi (a volte il valore stampato nelle keys è "Metadata")
        let metaKeyCandidates = [
            kCGImageAuxiliaryDataInfoMetadata as String,
            "Metadata"
        ]

        var mdAny: Any? = nil
        for k in metaKeyCandidates {
            if let v = auxDict[k] {
                mdAny = v
                details += "      ✅ Found metadata under key: \(k)\n"
                break
            }
        }

        guard let mdAnyUnwrapped = mdAny else {
            details += "      HDRGainMap metadata: ❌ not found (tried \(metaKeyCandidates))\n"
            // (opzionale) dump keys per debug
            details += "      Aux keys are: \(auxDict.keys.sorted())\n"
            // continua
            continue
        }
        
        if let mdObj = auxDict[kCGImageAuxiliaryDataInfoMetadata as String] {
            details += "      Metadata CFType: \(cfTypeDescription(mdObj))\n"

            // Caso 1: CGImageMetadata
            if CFGetTypeID(mdObj as CFTypeRef) == CGImageMetadataGetTypeID() {
                let cgmd = mdObj as! CGImageMetadata

                if let xmp = CGImageMetadataCreateXMPData(cgmd, nil) as Data?,
                   let xmpStr = String(data: xmp, encoding: .utf8) {
                    // (debug) se vuoi stampare tutto:
                    // details += "      XMP:\n\(xmpStr)\n"

                    if xmpStr.contains("HDRGainMapVersion") {
                        details += "      HDRGainMapVersion: ✅ present in XMP\n"
                    } else {
                        details += "      HDRGainMapVersion: ❌ not found in XMP\n"
                    }
                } else {
                    details += "      ⚠️ Could not export CGImageMetadata to XMP\n"
                }
            }

            // Caso 2: a volte è CFData (già XMP o simili)
            else if CFGetTypeID(mdObj as CFTypeRef) == CFDataGetTypeID(),
                    let data = mdObj as? Data,
                    let s = String(data: data, encoding: .utf8) {
                details += "      Metadata is CFData (utf8 len \(s.count))\n"
                details += s.contains("HDRGainMapVersion")
                    ? "      HDRGainMapVersion: ✅ present in data\n"
                    : "      HDRGainMapVersion: ❌ not found in data\n"
            } else {
                details += "      HDRGainMap metadata: present but unhandled type\n"
            }
            
            if CFGetTypeID(mdObj as CFTypeRef) == CGImageMetadataGetTypeID() {
                let cgmd = mdObj as! CGImageMetadata
                if let tags = CGImageMetadataCopyTags(cgmd) as? [CGImageMetadataTag] {
                    for tag in tags {
                        let ns = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? "?"
                        let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? "?"
                        let name = (CGImageMetadataTagCopyName(tag) as String?) ?? "?"
                        let value = CGImageMetadataTagCopyValue(tag)
                        details += "      TAG ns=\(ns) prefix=\(prefix) name=\(name) value=\(String(describing: value))\n"
                    }
                }
            }

        }

        details += "      Metadata value type: \(type(of: mdAnyUnwrapped))\n"

        // Cast robusto
        let mdDict: [AnyHashable: Any]?
        if let d = mdAnyUnwrapped as? [AnyHashable: Any] {
            mdDict = d
        } else if let d = mdAnyUnwrapped as? NSDictionary {
            mdDict = d as? [AnyHashable: Any]
        } else {
            mdDict = nil
        }

        if let md = mdDict {
            details += "      Metadata keys: \(md.keys.map { "\($0)" }.sorted())\n"
            if let v = md["HDRGainMapVersion"] {
                details += "      HDRGainMapVersion: \(v)\n"
            } else {
                details += "      HDRGainMapVersion: ❌ missing\n"
            }
        } else {
            details += "      HDRGainMap metadata: ⚠️ present but not a dictionary we can read\n"
        }
        
    }
    
    // opzionale: riepilogo chiaro
    details += "\n   Apple HDRGainMap: \(hasAppleGainMap ? "✅" : "❌")\n"
    details += "   ISO GainMap:      \(hasISOGainMap ? "✅" : "❌")\n"
    
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
    
//    // Check EXIF/IPTC preservation
//    if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
//
//        details += "\n📋 METADATA PRESERVATION:\n"
//
//        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
//            details += "   ✅ EXIF: FOUND (\(exif.count) entries)\n"
//
//            // Mostra alcuni campi comuni
//            if let dateTime = exif["DateTimeOriginal"] as? String {
//                details += "      - Date: \(dateTime)\n"
//            }
//            if let make = exif["Make"] as? String {
//                details += "      - Camera Make: \(make)\n"
//            }
//        } else {
//            details += "   ⚠️  EXIF: NOT FOUND\n"
//        }
//
//        if let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
//            details += "   ✅ IPTC: FOUND (\(iptc.count) entries)\n"
//
//            if let copyright = iptc["CopyrightNotice"] as? String {
//                details += "      - Copyright: \(copyright)\n"
//            }
//        } else {
//            details += "   ⚠️  IPTC: NOT FOUND\n"
//        }
//
//        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
//            details += "   ✅ TIFF: FOUND (\(tiff.count) entries)\n"
//        } else {
//            details += "   ⚠️  TIFF: NOT FOUND\n"
//        }
//
//        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
//            details += "   ✅ GPS: FOUND (\(gps.count) entries)\n"
//        }
//    }
    
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
print("   Apple Metadata:  \(hasMakerApple ? "present (legacy)" : "absent (expected for ISO output)")")
// A gain map under any scheme (ISO 21496-1 or legacy Apple) counts as valid. The maker tags
// are intentionally absent for ISO output, so they no longer gate validity.
print("   Overall Result:  \(hasGainMap ? "✅ VALID" : "❌ INVALID")")
print(String(repeating: "=", count: 70) + "\n")

exit(hasGainMap ? 0 : 1)
