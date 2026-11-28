namespace Toki.Windows;

internal static class Program {
    [STAThread]
    private static int Main(string[] args) {
        var smokeTest = args.Contains("--smoke-test", StringComparer.OrdinalIgnoreCase);
        if (smokeTest) {
            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
        }
        ApplicationConfiguration.Initialize();

        var instanceName = smokeTest ? $"Local\\Toki.Windows.Smoke.{Environment.ProcessId}" : @"Local\Toki.Windows.Preview";
        using var showSignal = new EventWaitHandle(false, EventResetMode.AutoReset, instanceName + ".Show");
        using var instanceMutex = new Mutex(true, instanceName, out var isFirstInstance);
        if (!isFirstInstance && !smokeTest) {
            showSignal.Set();
            return 0;
        }

        try {
            using var context = new ApplicationContext();
            using var form = new MainForm(smokeTest, showSignal);
            form.FormClosed += (_, _) => context.ExitThread();
            form.Start();
            Application.Run(context);
            return 0;
        } catch (Exception exception) when (smokeTest) {
            Console.Error.WriteLine($"Toki smoke test failed: {exception.Message}");
            return 1;
        }
    }
}
