using Microsoft.UI.Xaml.Controls;
using Decant.Engine;

namespace Decant.Views;

public sealed partial class FirmwarePage : UserControl, ITabPage
{
    Session session = null!;
    MainWindow window = null!;

    public FirmwarePage() { InitializeComponent(); }

    public void Attach(Session s, MainWindow w) { session = s; window = w; }

    public void Shown() { }
}
