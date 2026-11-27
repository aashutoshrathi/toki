using Toki.Core.Tests;

if (Environment.GetEnvironmentVariable("TOKI_FAKE_APP_SERVER") == "1") {
    await FakeAppServer.RunAsync();
    return 0;
}

QuotaWindowTests.Run();
ApiContractTests.Run();
SettingsStoreTests.Run();
ClaudeCredentialTests.Run();
ClaudeUsageParserTests.Run();
await ClaudeProviderTests.RunAsync();
CodexParserTests.Run();
CodexBinaryTests.Run();
await CodexTransportTests.RunAsync();
await UsageReaderTests.RunAsync();
return TestHarness.Finish();
