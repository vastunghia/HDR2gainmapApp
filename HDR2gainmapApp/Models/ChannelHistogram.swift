/// Histogram data for a single channel
class ChannelHistogram {
    let bins: [Float]       // Normalized [0,1] counts for each bin
    let binCount: Int       // Number of bins
    let range: ClosedRange<Float>  // Value range (e.g. 0...peak for HDR)
    
    init(bins: [Float], binCount: Int, range: ClosedRange<Float>) {
        self.bins = bins
        self.binCount = binCount
        self.range = range
    }
    
    /// X value for bin index (bin center)
    func xValue(for index: Int) -> Float {
        let binWidth = (range.upperBound - range.lowerBound) / Float(binCount)
        return range.lowerBound + (Float(index) + 0.5) * binWidth
    }
}
