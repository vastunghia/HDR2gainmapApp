import SwiftUI
import AppKit

/// Native NSWindow controller for the clipping legend that stays always on top
class ClippingLegendWindowController: NSWindowController {
    
    // private var viewModel: MainViewModel?
    
    convenience init(viewModel: MainViewModel) {
        // Default size large enough to show the whole legend + stats without resizing,
        // capped to the available screen height so it never spills off-screen.
        let screen = NSApp.mainWindow?.screen ?? NSScreen.main
        let availableHeight = (screen?.visibleFrame.height ?? 1000) - 40
        let defaultHeight: CGFloat = min(960, availableHeight)

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: defaultHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Clipping Legend & Statistics"
        window.isReleasedWhenClosed = false

        // Make it float above other windows
        window.level = .floating

        // Allow interaction with windows below
        window.hidesOnDeactivate = false

        // Set minimum size
        window.minSize = NSSize(width: 350, height: 560)

        // Position near the main window
        if let mainWindow = NSApp.mainWindow {
            let mainFrame = mainWindow.frame
            let newOrigin = NSPoint(
                x: mainFrame.maxX + 20,
                y: mainFrame.maxY - defaultHeight
            )
            window.setFrameOrigin(newOrigin)
        } else {
            window.center()
        }
        
        self.init(window: window)
        // self.viewModel = viewModel
        
        // Set the SwiftUI view as content
        let contentView = ClippingLegendContentView(viewModel: viewModel)
        window.contentView = NSHostingView(rootView: contentView)
    }
    
    /// Show the window
    func show() {
        window?.makeKeyAndOrderFront(nil)
    }
    
    /// Hide the window
    func hide() {
        window?.orderOut(nil)
    }
}

/// SwiftUI content for the legend window
struct ClippingLegendContentView: View {
    @Bindable var viewModel: MainViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // ✅ Header removed - using native window title bar only
            
            // Content
            if let stats = viewModel.detailedClippingStats {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Diagram
                        VStack(spacing: 12) {
                            Text("Additive Color Model (RGB)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            // RGB diagram with fixed aspect ratio
                            RGBDiagramView(stats: stats)
                                .aspectRatio(1.0, contentMode: .fit)
                                .frame(maxWidth: 300)
                                .background(Color.black)
                                .cornerRadius(8)
                        }
                        .frame(maxWidth: .infinity)   // center the diagram block
                        .padding(.top)  // Add top padding since we removed the header
                        
                        Divider()
                        
                        // Statistics - Two-column layout
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Clipped Pixels by Category")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            
                            // ✅ Updated header row with new column names
                            HStack(spacing: 8) {
                                Text("")
                                    .frame(width: 24) // Color swatch width
                                Text("Category")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("with luma < 1")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .trailing)
                                Text("with luma clipped")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .trailing)
                            }
                            .padding(.horizontal, 12)
                            
                            Divider()
                            
                            // Primary colors
                            TwoColumnStatRow(
                                label: "Red only",
                                color: .red,
                                brightCount: stats.redOnly,
                                dimCount: stats.redDim,
                                total: stats.total
                            )
                            
                            TwoColumnStatRow(
                                label: "Green only",
                                color: .green,
                                brightCount: stats.greenOnly,
                                dimCount: stats.greenDim,
                                total: stats.total
                            )
                            
                            TwoColumnStatRow(
                                label: "Blue only",
                                color: .blue,
                                brightCount: stats.blueOnly,
                                dimCount: stats.blueDim,
                                total: stats.total
                            )
                            
                            Divider()
                            
                            // Secondary colors
                            TwoColumnStatRow(
                                label: "Yellow (R+G)",
                                color: .yellow,
                                brightCount: stats.yellowBright,
                                dimCount: stats.yellowDim,
                                total: stats.total
                            )
                            
                            TwoColumnStatRow(
                                label: "Magenta (R+B)",
                                color: Color(red: 1, green: 0, blue: 1),
                                brightCount: stats.magentaBright,
                                dimCount: stats.magentaDim,
                                total: stats.total
                            )
                            
                            TwoColumnStatRow(
                                label: "Cyan (G+B)",
                                color: .cyan,
                                brightCount: stats.cyanBright,
                                dimCount: stats.cyanDim,
                                total: stats.total
                            )
                            
                            Divider()
                            
                            // ✅ All channels (aligned to second column)
                            HStack(spacing: 12) {
                                // Color swatch (white = R+G+B fully clipped)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white)
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                                    )
                                
                                Text("White (R+G+B)")
                                    .font(.subheadline)
                                
                                Spacer()
                                
                                // Empty space for first column
                                Text("")
                                    .frame(width: 90)
                                
                                // Count in second column (luma clipped)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(stats.white.formatted())")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .monospacedDigit()
                                    
                                    if stats.white > 0 {
                                        Text(formatPercentTwoSig(Double(stats.white) / Double(stats.total) * 100))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    } else {
                                        Text(" ")
                                            .font(.caption2)
                                    }
                                }
                                .frame(width: 90, alignment: .trailing)
                            }
                            .padding(.horizontal, 12)
                            
                            Divider()
                            
                            // Total
                            HStack {
                                Text("Total clipped")
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("\(stats.totalClipped.formatted()) (\(formatPercentTwoSig(Double(stats.totalClipped) / Double(stats.total) * 100)))")
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                    .padding()
                }
            } else {
                // No stats available
                VStack(spacing: 16) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No clipping statistics available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Enable 'Show clipped pixels' to see detailed statistics")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top)  // Add top padding
            }
        }
    }
}

// Two-column stat row remains the same
struct TwoColumnStatRow: View {
    let label: String
    let color: Color
    let brightCount: Int
    let dimCount: Int
    let total: Int
    
    var body: some View {
        HStack(spacing: 12) {
            // Color swatch
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 24, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                )
            
            // Label
            Text(label)
                .font(.subheadline)
            
            Spacer()
            
            // First column (luma < 1)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(brightCount.formatted())")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .monospacedDigit()
                
                if brightCount > 0 {
                    Text(formatPercentTwoSig(Double(brightCount) / Double(total) * 100))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(" ")
                        .font(.caption2)
                }
            }
            .frame(width: 90, alignment: .trailing)
            
            // Second column (luma clipped)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(dimCount.formatted())")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .monospacedDigit()
                
                if dimCount > 0 {
                    Text(formatPercentTwoSig(Double(dimCount) / Double(total) * 100))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(" ")
                        .font(.caption2)
                }
            }
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 12)
    }
}


/// Simple RGB diagram drawn with SwiftUI using Canvas. Each region is labelled with the share of
/// clipped pixels in that channel/combination (bright + luma-clipped summed).
struct RGBDiagramView: View {
    let stats: HDRProcessor.DetailedClippingStats

    /// Formats `count` as a percentage of the total pixel count.
    private func pct(_ count: Int) -> String {
        guard stats.total > 0 else { return "0%" }
        return formatPercentTwoSig(Double(count) / Double(stats.total) * 100)
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 4.0

            // Helper to draw a circle with blend mode
            func drawCircle(at offset: CGSize, color: Color) {
                var path = Path()
                path.addEllipse(in: CGRect(
                    x: center.x + offset.width - radius,
                    y: center.y + offset.height - radius,
                    width: radius * 2,
                    height: radius * 2
                ))

                context.fill(path, with: .color(color))
            }

            // Enable blend mode for additive color mixing
            context.blendMode = .plusLighter

            // Red circle (top)
            drawCircle(at: CGSize(width: 0, height: -radius * 0.5), color: .red)

            // Green circle (bottom-left)
            drawCircle(at: CGSize(width: -radius * 0.7 * sqrt(3.0)/2.0, height: radius * 0.7 * 0.5), color: .green)

            // Blue circle (bottom-right)
            drawCircle(at: CGSize(width: radius * 0.7 * sqrt(3.0)/2.0, height: radius * 0.7 * 0.5), color: .blue)

            // Reset blend mode for labels
            context.blendMode = .normal

            // Label fonts
            let primaryLabelFont = Font.system(size: 12, weight: .bold)
            let secondaryLabelFont = Font.system(size: 11, weight: .semibold)

            // Single-channel % (in the pure lobes, white text on the dark background).
            // R (top)
            context.draw(
                Text(pct(stats.redOnly + stats.redDim)).font(primaryLabelFont).foregroundColor(.white),
                at: CGPoint(x: center.x, y: center.y - radius * 1.2)
            )
            // G (bottom-left)
            context.draw(
                Text(pct(stats.greenOnly + stats.greenDim)).font(primaryLabelFont).foregroundColor(.white),
                at: CGPoint(x: center.x - radius * 1.1, y: center.y + radius * 0.77)
            )
            // B (bottom-right)
            context.draw(
                Text(pct(stats.blueOnly + stats.blueDim)).font(primaryLabelFont).foregroundColor(.white),
                at: CGPoint(x: center.x + radius * 1.1, y: center.y + radius * 0.77)
            )

            // Two-channel % (in overlap areas, black text).
            // Y = R+G (top-left)
            context.draw(
                Text(pct(stats.yellowBright + stats.yellowDim)).font(secondaryLabelFont).foregroundColor(.black),
                at: CGPoint(x: center.x - radius * 0.5, y: center.y - radius * 0.4)
            )
            // M = R+B (top-right)
            context.draw(
                Text(pct(stats.magentaBright + stats.magentaDim)).font(secondaryLabelFont).foregroundColor(.black),
                at: CGPoint(x: center.x + radius * 0.5, y: center.y - radius * 0.4)
            )
            // C = G+B (bottom)
            context.draw(
                Text(pct(stats.cyanBright + stats.cyanDim)).font(secondaryLabelFont).foregroundColor(.black),
                at: CGPoint(x: center.x, y: center.y + radius * 0.6)
            )

            // Triple overlap % (center, black text).
            context.draw(
                Text(pct(stats.white)).font(secondaryLabelFont).foregroundColor(.black),
                at: center
            )
        }
        .frame(minWidth: 200, minHeight: 200)
    }
}
