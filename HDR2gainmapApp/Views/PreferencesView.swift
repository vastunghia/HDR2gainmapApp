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
    
    @AppStorage("heicExportQuality")
    private var heicExportQuality: Double = 0.97
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Preferences")
                .font(.title2.weight(.bold))
            
            // Export settings
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Export")
                        .font(.headline)
                    
                    // Encoding method
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
                        .frame(maxWidth: 420)
                    }
                    
                    Divider()
                        .padding(.vertical, 4)
                    
                    // HEIC Quality
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("HEIC Quality")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.2f", heicExportQuality))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        
                        Slider(value: $heicExportQuality, in: 0.5...1.0, step: 0.01)
                        
                        HStack {
                            Text("Lower")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("Higher")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    
                    Text("""
                         Choose the Core Image writer used for final HEIF export and the quality level. \
                         Higher quality produces larger files with better image fidelity.
                         """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(14)
                
                HStack {
                    Spacer()
                    Button("Reset defaults") {
                        exportMethodSelectionID = ExportMethodChoice.heif.rawValue
                        heicExportQuality = 0.97
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 640, height: 360)
        .closeOnEscape()
    }
}
