// Every tab page attaches to the session once and is told when it comes to the front.
namespace Decant.Views;

public interface ITabPage
{
    void Attach(Engine.Session s, MainWindow w);
    void Shown();
}
