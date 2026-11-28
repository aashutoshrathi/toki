namespace Toki.Core;

public static class SessionFilter {
    public static IReadOnlyList<LocalSession> Apply(IReadOnlyList<LocalSession> sessions, string? provider, string query) {
        var words = query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        return sessions.Where(session => (provider is null || session.Provider == provider)
            && words.All(word => session.Title.Contains(word, StringComparison.OrdinalIgnoreCase)
                || (session.Directory?.Contains(word, StringComparison.OrdinalIgnoreCase) ?? false)))
            .ToArray();
    }
}
