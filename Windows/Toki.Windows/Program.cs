namespace Toki.Windows;

internal static class Program {
    [STAThread]
    private static int Main(string[] args) {
        var smokeTest = args.Contains("--smoke-test", StringComparer.OrdinalIgnoreCase);
        if (smokeTest) {
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
        }
        ApplicationConfiguration.Initialize();

        using var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Toki.Windows.Preview.Show");
        using var instanceMutex = new Mutex(true, @"Local\Toki.Windows.Preview", out var isFirstInstance);
        if (!isFirstInstance && !smokeTest) {
            showSignal.Set();
            return 0;
        }

        try {
            Application.Run(new MainForm(smokeTest, showSignal));
            return 0;
        } catch (Exception exception) when (smokeTest) {
            Console.Error.WriteLine($"Toki smoke test failed: {exception.Message}");
            return 1;
        }
    }
}
