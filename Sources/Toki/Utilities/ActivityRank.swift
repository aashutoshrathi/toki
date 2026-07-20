import Foundation

// Shared by the popover heatmap and the terminal one, which differ only in how many shades
// they have to spend. Two copies of this drifting apart would show the same day at different
// intensities in the app and the CLI, with nothing to indicate which one was wrong.
enum ActivityRank {
    // Rank-based rather than proportional: one heavy day would otherwise flatten every other
    // day to the lowest shade. Position among the distinct totals is what gets coloured.
    static func level(_ value: Int, among distinct: [Int], steps: Int) -> Int {
        let top = max(steps - 1, 0)
        // A single active day is by definition the busiest one; showing it at the lowest shade
        // would read as "barely anything happened".
        guard distinct.count > 1, let index = distinct.firstIndex(of: value) else { return top }
        return index * top / (distinct.count - 1)
    }
}
