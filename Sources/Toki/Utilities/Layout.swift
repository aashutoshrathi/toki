import AppKit

func popoverWidth() -> CGFloat {
    // 390, not 350 - the header row needs room for 5 icon buttons (session, refresh,
    // changelog, settings, quit) plus the "/toki" wordmark and version badge without
    // wrapping or crowding.
    min(390, max(360, (NSScreen.main?.visibleFrame.width ?? 390) - 32))
}

func popoverHeight(
    insightEnabled: Bool = false,
    quotaAccountCount: Int = 0,
    visibleHeight: CGFloat? = nil
) -> CGFloat {
    // Quota space includes its header, padding, and the taller of the ring or account cards.
    let quotaHeight: CGFloat = quotaAccountCount > 0
        ? 60 + max(96, CGFloat(quotaAccountCount) * 56 + CGFloat(quotaAccountCount - 1) * 6)
        : 0
    let desiredHeight: CGFloat = 500 + (insightEnabled ? 64 : 0) + quotaHeight
    let availableHeight = (visibleHeight ?? NSScreen.main?.visibleFrame.height ?? 596) - 96
    return min(desiredHeight, max(0, availableHeight))
}
