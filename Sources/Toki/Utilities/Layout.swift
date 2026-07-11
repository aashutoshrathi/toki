import AppKit

func popoverWidth() -> CGFloat {
    min(350, max(320, (NSScreen.main?.visibleFrame.width ?? 350) - 32))
}

func popoverHeight() -> CGFloat {
    min(500, max(340, (NSScreen.main?.visibleFrame.height ?? 500) - 96))
}

func accountListHeight() -> CGFloat {
    max(130, popoverHeight() - 258)
}
