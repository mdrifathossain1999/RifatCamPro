using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using RifatCamPro.Client.ViewModels;

namespace RifatCamPro.Client;

public partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        Loaded += OnMainWindowLoaded;
    }

    private void OnMainWindowLoaded(object sender, RoutedEventArgs e)
    {
        var viewModel = DataContext as MainViewModel;
        if (viewModel == null) return;

        KeyDown += (_, args) =>
        {
            if (args.Key == Key.Enter && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
            {
                viewModel.ConnectCommand.Execute(null);
            }
            else if (args.Key == Key.D && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
            {
                viewModel.DisconnectCommand.Execute(null);
            }
            else if (args.Key == Key.R && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
            {
                viewModel.ScanCommand.Execute(null);
            }
            else if (args.Key == Key.F5)
            {
                viewModel.ScanCommand.Execute(null);
            }
        };

        PasswordBox.PasswordChanged += (_, _) =>
        {
            viewModel.Password = PasswordBox.Password;
        };

        Closing += (_, _) =>
        {
            viewModel.Dispose();
        };
    }
}

public class NullToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var invert = parameter is string s && s == "Invert";
        var isNull = value == null;
        return (invert ? isNull : !isNull) ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotImplementedException();
}

public class NullToImageSourceConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        if (value is System.Windows.Media.Imaging.WriteableBitmap bitmap)
            return bitmap;
        return Binding.DoNothing;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotImplementedException();
}
