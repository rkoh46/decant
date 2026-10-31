using Microsoft.UI.Xaml;

namespace Decant;

public partial class App : Application
{
    public static Window? Window { get; private set; }
    public static readonly string LogFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Decant", "decant.log");

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => { Trace("Unhandled: " + e.Exception); };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Trace("Fatal: " + e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) => { Trace("Task: " + e.Exception); e.SetObserved(); };
    }

    /// Appends a line to %LOCALAPPDATA%\Decant\decant.log; the place to look when something is wrong.
    public static void Trace(string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogFile)!);
            File.AppendAllText(LogFile, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {line}\n");
        }
        catch { }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            Trace("Launch");
            Window = new MainWindow();
            Window.Activate();
            Trace("Window shown");
        }
        catch (Exception e) { Trace("Launch failed: " + e); throw; }
    }
}
