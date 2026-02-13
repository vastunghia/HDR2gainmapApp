#!/usr/bin/env swift

/// fix_gainmap.swift
///
/// Proof of Concept: prende un file .heic prodotto su macOS 26 (che contiene
/// una gain map con metadati HDRToneMap) e inietta i tag HDRGainMap classici
/// (namespace Apple http://ns.apple.com/HDRGainMap/1.0/) nell'auxiliary data,
/// in modo che Adobe Gain Map Demo App e altri tool riconoscano correttamente
/// il file come "SDR + Apple Gain Map".
///
/// Uso:
///   chmod +x fix_gainmap.swift
///   ./fix_gainmap.swift input.heic [output.heic]
///
/// Se output.heic non e' specificato, scrive <input>_fixed.heic nella stessa cartella.

import Foundation
import CoreFoundation
import ImageIO
import CoreGraphics

// MARK: - Entry point

func main() {
    guard CommandLine.arguments.count >= 2 else {
        print("Uso: fix_gainmap.swift <input.heic> [output.heic]")
        exit(1)
    }

    let inputPath = NSString(string: CommandLine.arguments[1]).expandingTildeInPath
    let outputPath: String
    if CommandLine.arguments.count >= 3 {
        outputPath = NSString(string: CommandLine.arguments[2]).expandingTildeInPath
    } else {
        let inputURL = URL(fileURLWithPath: inputPath)
        let base     = inputURL.deletingPathExtension().lastPathComponent
        outputPath   = inputURL.deletingLastPathComponent()
                               .appendingPathComponent("\(base)_fixed.heic")
                               .path
    }

    print("Input : \(inputPath)")
    print("Output: \(outputPath)\n")

    do {
        let headroom = try fixGainMap(
            inputURL:  URL(fileURLWithPath: inputPath),
            outputURL: URL(fileURLWithPath: outputPath)
        )
        print("\n✅ File scritto con successo.")
        print("   Headroom iniettato: \(String(format: "%.6f", headroom))")
        print("   Output: \(outputPath)")
    } catch {
        print("\n❌ Errore: \(error.localizedDescription)")
        exit(1)
    }
}

// MARK: - Errors

enum FixError: LocalizedError {
    case cannotOpenSource
    case noGainMap
    case noMetadata
    case cannotBuildMetadata
    case cannotCreateDestination
    case cannotFinalizeDestination
    case cannotReplaceFile

    var errorDescription: String? {
        switch self {
        case .cannotOpenSource:          return "Impossibile aprire il file sorgente"
        case .noGainMap:                 return "Nessuna auxiliary data HDRGainMap trovata"
        case .noMetadata:                return "Auxiliary data trovata ma senza metadati CGImageMetadata"
        case .cannotBuildMetadata:       return "Impossibile costruire il nuovo CGImageMetadata"
        case .cannotCreateDestination:   return "Impossibile creare CGImageDestination"
        case .cannotFinalizeDestination: return "CGImageDestinationFinalize ha fallito"
        case .cannotReplaceFile:         return "Impossibile sostituire il file di output"
        }
    }
}

// MARK: - Core logic

func fixGainMap(inputURL: URL, outputURL: URL) throws -> Float {

    // ── 1. Apri la sorgente ──────────────────────────────────────────────────
    guard let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
        throw FixError.cannotOpenSource
    }

    // ── 2. Leggi l'auxiliary data ────────────────────────────────────────────
    guard let rawAux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                src, 0, kCGImageAuxiliaryDataTypeHDRGainMap),
          let auxDict = rawAux as? [String: Any] else {
        throw FixError.noGainMap
    }

    print("🔍 Auxiliary data trovata.")
    print("   Chiavi: \(auxDict.keys.sorted().joined(separator: ", "))")

    // ── 3. Ispeziona i metadati esistenti e cattura AlternateHeadroom ─────────
    let metaKey = kCGImageAuxiliaryDataInfoMetadata as String
    guard let metaObj = auxDict[metaKey] else {
        throw FixError.noMetadata
    }

    print("\n🔍 Analisi metadati esistenti:")

    var alternateHeadroom: Float? = nil

    if CFGetTypeID(metaObj as CFTypeRef) == CGImageMetadataGetTypeID() {
        let cgmd = unsafeBitCast(metaObj as CFTypeRef, to: CGImageMetadata.self)

        if let tags = CGImageMetadataCopyTags(cgmd) as? [CGImageMetadataTag] {
            for tag in tags {
                let ns    = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? "?"
                let name  = (CGImageMetadataTagCopyName(tag) as String?)      ?? "?"
                let value = CGImageMetadataTagCopyValue(tag)
                print("   TAG \(ns) : \(name) = \(String(describing: value))")

                if name == "AlternateHeadroom", let v = value as? NSNumber {
                    alternateHeadroom = v.floatValue
                }
            }
        }
    }

    // ── 4. Determina l'headroom ──────────────────────────────────────────────
    //
    // Priorita':
    //  a) HDRToneMap:AlternateHeadroom  — valore diretto, il piu' preciso
    //  b) MakerApple tag 33/48          — ricavato invertendo la formula Apple
    //  c) Fallback 1.0
    //
    let headroom: Float

    if let ah = alternateHeadroom, ah > 1.0 {
        headroom = ah
        print("\n✅ Headroom da HDRToneMap:AlternateHeadroom = \(ah)")
    } else if let mh = readMakerAppleHeadroom(src: src) {
        headroom = mh
        print("\n✅ Headroom da MakerApple = \(mh)")
    } else {
        headroom = 1.0
        print("\n⚠️  Headroom non rilevato, uso fallback 1.0")
    }

    // ── 5. Costruisci i nuovi metadati HDRGainMap programmaticamente ──────────
    //
    // Non usiamo CGImageMetadataCreateFromXMPData perche' i tag HDRToneMap
    // contengono strutture annidate (ChannelMetadata con array di dizionari)
    // che non sopravvivono al round-trip XMP -> CGImageMetadata.
    //
    // Costruiamo i tag direttamente via CGImageMetadataSetValueWithPath.
    // I tag HDRToneMap originali restano intatti nell'auxDict (non li tocchiamo).
    //
    guard let newMeta = buildHDRGainMapMetadata(headroom: headroom) else {
        throw FixError.cannotBuildMetadata
    }

    print("\n🔍 Verifica tag nel nuovo CGImageMetadata:")
    if let tags = CGImageMetadataCopyTags(newMeta) as? [CGImageMetadataTag] {
        for tag in tags {
            let ns   = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? "?"
            let name = (CGImageMetadataTagCopyName(tag) as String?)      ?? "?"
            let val  = CGImageMetadataTagCopyValue(tag)
            print("   TAG \(ns) : \(name) = \(String(describing: val))")
        }
    }

    // ── 6. Ricostruisce l'auxiliary dict sostituendo solo i metadati ──────────
    var newAuxDict = auxDict
    newAuxDict[metaKey] = newMeta

    // ── 7. Scrivi il nuovo file HEIC ─────────────────────────────────────────
    let tempURL = outputURL.deletingLastPathComponent()
                           .appendingPathComponent(".__fix_tmp_\(UUID().uuidString).heic")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let utType = CGImageSourceGetType(src) ?? ("public.heic" as CFString)

    guard let dst = CGImageDestinationCreateWithURL(
            tempURL as CFURL, utType, 1, nil) else {
        throw FixError.cannotCreateDestination
    }

    // Copia l'immagine principale con le sue proprieta' originali
    if let cgImg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        let imgProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
        CGImageDestinationAddImage(dst, cgImg, imgProps)
        print("\n📷 Immagine principale copiata (\(cgImg.width)x\(cgImg.height))")
    }

    // Inietta l'auxiliary data patchata
    CGImageDestinationAddAuxiliaryDataInfo(
        dst,
        kCGImageAuxiliaryDataTypeHDRGainMap,
        newAuxDict as CFDictionary
    )
    print("📎 Auxiliary data HDRGainMap iniettata")

    guard CGImageDestinationFinalize(dst) else {
        throw FixError.cannotFinalizeDestination
    }

    // Sostituisce il file di output (via file temporaneo per atomicita')
    do {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
        }
    } catch {
        throw FixError.cannotReplaceFile
    }

    return headroom
}

// MARK: - Programmatic CGImageMetadata builder

/// Costruisce un CGImageMetadata con i tag richiesti da Adobe per riconoscere
/// il file come "Apple HDR Gain Map":
///
///   iio:hasXMP                    = True
///   HDRGainMap:HDRGainMapVersion  = 131072  (0x00020000, versione 2.0)
///   HDRGainMap:HDRGainMapHeadroom = <headroom lineare>
///
/// Usa CGImageMetadataSetValueWithPath — nessun round-trip XMP, nessun rischio
/// di fallire su tag strutturati complessi (es. HDRToneMap:ChannelMetadata).
func buildHDRGainMapMetadata(headroom: Float) -> CGImageMetadata? {

    let meta = CGImageMetadataCreateMutable()

    let iioNS     = "http://ns.apple.com/ImageIO/1.0/"    as CFString
    let iioPrefix = "iio"                                  as CFString
    let gmNS      = "http://ns.apple.com/HDRGainMap/1.0/" as CFString
    let gmPrefix  = "HDRGainMap"                           as CFString

    // Registra i namespace prima di scrivere i tag
    CGImageMetadataRegisterNamespaceForPrefix(meta, iioNS, iioPrefix, nil)
    CGImageMetadataRegisterNamespaceForPrefix(meta, gmNS,  gmPrefix,  nil)

    // iio:hasXMP = True
    CGImageMetadataSetValueWithPath(
        meta, nil,
        "iio:hasXMP" as CFString,
        kCFBooleanTrue
    )

    // HDRGainMap:HDRGainMapVersion = 131072
    CGImageMetadataSetValueWithPath(
        meta, nil,
        "HDRGainMap:HDRGainMapVersion" as CFString,
        NSNumber(value: 131_072)
    )

    // HDRGainMap:HDRGainMapHeadroom = <headroom>
    CGImageMetadataSetValueWithPath(
        meta, nil,
        "HDRGainMap:HDRGainMapHeadroom" as CFString,
        NSNumber(value: headroom)
    )

    return meta
}

// MARK: - MakerApple headroom reader (fallback)

/// Legge i tag MakerApple 33 e 48 e ricostruisce l'headroom invertendo
/// la formula Apple documentata in:
/// https://developer.apple.com/documentation/appkit/applying-apple-hdr-effect-to-your-photos
func readMakerAppleHeadroom(src: CGImageSource) -> Float? {
    guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
          let maker = props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
          let m33   = (maker["33"] as? NSNumber)?.floatValue,
          let m48   = (maker["48"] as? NSNumber)?.floatValue else {
        return nil
    }

    print("   MakerApple: tag33=\(m33) tag48=\(m48)")

    let headroom: Float
    if m33 >= 1.0 {
        headroom = m48 <= 0.01 ? 3.0 - m48 * 70.0 : 2.303 - m48 * 0.303
    } else {
        headroom = m48 <= 0.01 ? 1.8 - m48 * 20.0 : 1.601 - m48 * 0.101
    }

    return max(1.0, headroom)
}

// MARK: - Run

main()
