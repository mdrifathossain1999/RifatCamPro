using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using RifatCamPro.Client.Services;
using RifatCamPro.Client.ViewModels;

namespace RifatCamPro.Client;

public partial class App : Application
{
    private ServiceProvider? _serviceProvider;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var services = new ServiceCollection();
        ConfigureServices(services);
        _serviceProvider = services.BuildServiceProvider();

        var mainWindow = _serviceProvider.GetRequiredService<MainWindow>();
        mainWindow.DataContext = _serviceProvider.GetRequiredService<MainViewModel>();
        mainWindow.Show();
    }

    private static void ConfigureServices(IServiceCollection services)
    {
        services.AddSingleton<NetworkClient>();
        services.AddSingleton<VirtualCamera>();
        services.AddSingleton<SettingsManager>();
        services.AddSingleton<MainViewModel>();
        services.AddSingleton<MainWindow>();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_serviceProvider != null)
        {
            _serviceProvider.Dispose();
        }
        base.OnExit(e);
    }
}
