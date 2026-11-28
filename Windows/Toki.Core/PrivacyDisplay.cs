namespace Toki.Core;

public static class PrivacyDisplay {
    public static ProviderSnapshot Snapshot(ProviderSnapshot snapshot, bool hidden) => hidden
        ? snapshot with { Detail = "Account details hidden", Error = snapshot.Error is null ? null : "Provider unavailable. Reveal details to see the error." }
        : snapshot;
}
