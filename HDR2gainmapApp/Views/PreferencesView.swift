import SwiftUI
import AppKit

struct PreferencesView: View {
    
    @AppStorage("exportMethodSelectionID")
    private var exportMethodSelectionID: String = ExportMethodChoice.heif.rawValue
    private var exportMethodBinding: Binding<ExportMethodChoice> {
        Binding(
            get: { ExportMethodChoice(rawValue: exportMethodSelectionID) ?? .heif },
            set: { exportMethodSelectionID = $0.rawValue }
        )
    }
    
//    @AppStorage("clippingMetricID")
//    private var clippingMetricID: String = ClippingMetricChoice.luminance.rawValue
//    
//    private var clippingMetricBinding: Binding<ClippingMetricChoice> {
//        Binding(
//            get: { ClippingMetricChoice(rawValue: clippingMetricID) ?? .luminance },
//            set: { clippingMetricID = $0.rawValue }
//        )
//    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preferences")
                .font(.title2.weight(.bold))
            
            // Use a simple VStack instead of Form's label column to avoid wrapping.
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Encoding method")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        
                        Picker("", selection: exportMethodBinding) {
                            ForEach(ExportMethodChoice.allCases) { c in
                                Text(c.label).tag(c)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 420) // keeps segments on one line on most displays
                    }
                    
                    Text("""
                         Choose the Core Image writer used for final HEIF export.
                         Default is writeHEIFRepresentation().
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(14)
//                Text("Preview").font(.title3).bold()
//                VStack(alignment: .leading, spacing: 12) {
//                    Text("Preview")
//                        .font(.headline)
//                    
//                    VStack(alignment: .leading, spacing: 8) {
//                        Text("Clipping metric")
//                            .font(.subheadline)
//                            .foregroundStyle(.secondary)
//                        
//                        Picker("", selection: clippingMetricBinding) {
//                            ForEach(ClippingMetricChoice.allCases) { c in
//                                Text(c.label).tag(c)
//                            }
//                        }
//                        .pickerStyle(.segmented)
//                        .labelsHidden()
//                        .frame(maxWidth: 420)
//                        
//                        Text((ClippingMetricChoice(rawValue: clippingMetricID) ?? .luminance).help)
//                            .font(.footnote)
//                            .foregroundStyle(.secondary)
//                    }
//                }
//                .padding(14)
                HStack {
                    Spacer()
                    Button("Reset defaults") {
                        exportMethodSelectionID = ExportMethodChoice.heif.rawValue
//                        clippingMetricID = ClippingMetricChoice.anyChannel.rawValue
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 640, height: 480)
        .closeOnEscape()   // ← Esc now closes the Preferences window
    }
}
