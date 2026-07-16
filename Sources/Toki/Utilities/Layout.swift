import AppKit

func popoverWidth() -> CGFloat {
    // 390, not 350 - the header row needs room for 5 icon buttons (session, refresh,
    // changelog, settings, quit) plus the "/toki" wordmark and version badge without
    // wrapping or crowding.
    min(390, max(360, (NSScreen.main?.visibleFrame.width ?? 390) - 32))
}

func popoverHeight() -> CGFloat {
    min(500, max(340, (NSScreen.main?.visibleFrame.height ?? 500) - 96))
}

func accountListHeight() -> CGFloat {
    max(170, popoverHeight() - 202)
}
