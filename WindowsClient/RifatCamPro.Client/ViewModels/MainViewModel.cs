using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RifatCamPro.Client.Models;
using RifatCamPro.Client.Services;

namespace RifatCamPro.Client.ViewModels;

public partial class MainViewModel : ObservableObject, IDisposable
{
    private readonly NetworkClient _networkClient;
    private readonly VirtualCamera _virtualCamera;
    private readonly SettingsManager _settingsManager;
    private readonly System.Timers.Timer _statsTimer;
    private readonly System.Timers.Timer _reconnectTimer;

    private readonly object _bitmapLock = new();
    private DateTime _lastFrameTime = DateTime.Now;

    [ObservableProperty] private ObservableCollection<DiscoveredDevice> _discoveredDevices = new();
    [ObservableProperty] private DiscoveredDevice? _selectedDevice;
    [ObservableProperty] private ConnectionSettings _settings = new();
    [ObservableProperty] private StreamStats _stats = new();
    [ObservableProperty] private DeviceStatus _status = DeviceStatus.Disconnected;
    [ObservableProperty] private WriteableBitmap? _videoFrame;
    [ObservableProperty] private string _statusMessage = "Ready";
    [ObservableProperty] private string _connectionStatusText = "Disconnected";
    [ObservableProperty] private string _bitrateText = "0 kbps";
    [ObservableProperty] private string _latencyText = "0 ms";
    [ObservableProperty] private string _fpsText = "0 FPS";
    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private bool _isVirtualCameraRunning;
    [ObservableProperty] private string _virtualCameraButtonText = "Start Virtual Camera";
    [ObservableProperty] private bool _torchEnabled;
    [ObservableProperty] private string _windowTitle = "RifatCam Pro";
    [ObservableProperty] private string _hostAddress = string.Empty;
    [ObservableProperty] private int _port = 4747;
    [ObservableProperty] private string _password = string.Empty;
    [ObservableProperty] private StreamProtocol _selectedProtocol = StreamProtocol.Mjpeg;
    [ObservableProperty] private StreamResolution _selectedResolution = StreamResolution.R1920x1080;
    [ObservableProperty] private int _selectedFps = 30;
    [ObservableProperty] private bool _autoReconnect = true;

    public ObservableCollection<string> AvailableResolutions { get; } = new()
    {
        "640x480", "1280x720", "1920x1080", "2560x1440", "3840x2160"
    };

    public ObservableCollection<string> AvailableFps { get; } = new()
    {
        "15", "24", "25", "30", "60"
    };

    public ObservableCollection<string> AvailableProtocols { get; } = new()
    {
        "MJPEG", "H.264"
    };

    public int SelectedProtocolIndex
    {
        get => (int)SelectedProtocol;
        set
        {
            if ((int)SelectedProtocol != value)
            {
                SelectedProtocol = (StreamProtocol)value;
                OnPropertyChanged();
            }
        }
    }

    public int SelectedResolutionIndex
    {
        get => (int)SelectedResolution;
        set
        {
            if ((int)SelectedResolution != value)
            {
                SelectedResolution = (StreamResolution)value;
                OnPropertyChanged();
            }
        }
    }

    public int SelectedFpsIndex
    {
        get
        {
            var fpsValues = new[] { 15, 24, 25, 30, 60 };
            var idx = Array.IndexOf(fpsValues, SelectedFps);
            return idx >= 0 ? idx : 3;
        }
        set
        {
            var fpsValues = new[] { 15, 24, 25, 30, 60 };
            if (value >= 0 && value < fpsValues.Length)
            {
                SelectedFps = fpsValues[value];
                OnPropertyChanged();
            }
        }
    }

    protected override void OnPropertyChanged(PropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (e.PropertyName == nameof(SelectedProtocol))
            OnPropertyChanged(nameof(SelectedProtocolIndex));
        if (e.PropertyName == nameof(SelectedResolution))
            OnPropertyChanged(nameof(SelectedResolutionIndex));
        if (e.PropertyName == nameof(SelectedFps))
            OnPropertyChanged(nameof(SelectedFpsIndex));
    }

    partial void OnSelectedDeviceChanged(DiscoveredDevice? value)
    {
        if (value?.Address != null)
        {
            HostAddress = value.Address.ToString();
            Port = value.Port;
        }
    }

    public ICommand ScanCommand { get; }
    public ICommand ConnectCommand { get; }
    public ICommand DisconnectCommand { get; }
    public ICommand ToggleVirtualCameraCommand { get; }
    public ICommand ToggleTorchCommand { get; }
    public ICommand SwitchCameraCommand { get; }
    public ICommand ExitCommand { get; }
    public ICommand AboutCommand { get; }

    public MainViewModel(
        NetworkClient networkClient,
        VirtualCamera virtualCamera,
        SettingsManager settingsManager)
    {
        _networkClient = networkClient;
        _virtualCamera = virtualCamera;
        _settingsManager = settingsManager;

        _networkClient.FrameReceived += OnFrameReceived;
        _networkClient.StatsUpdated += OnStatsUpdated;
        _networkClient.StatusChanged += OnStatusChanged;
        _networkClient.ErrorOccurred += OnErrorOccurred;

        _virtualCamera.StateChanged += OnVirtualCameraStateChanged;

        _settingsManager.Load();
        Settings = _settingsManager.Settings;
        HostAddress = Settings.HostAddress;
        Port = Settings.Port;
        Password = Settings.Password;
        SelectedProtocol = Settings.Protocol;
        SelectedResolution = Settings.Resolution;
        SelectedFps = Settings.TargetFps;
        AutoReconnect = Settings.AutoReconnect;

        ScanCommand = new AsyncRelayCommand(ExecuteScanAsync);
        ConnectCommand = new AsyncRelayCommand(ExecuteConnectAsync);
        DisconnectCommand = new RelayCommand(ExecuteDisconnect);
        ToggleVirtualCameraCommand = new RelayCommand(ExecuteToggleVirtualCamera);
        ToggleTorchCommand = new AsyncRelayCommand(ExecuteToggleTorchAsync);
        SwitchCameraCommand = new AsyncRelayCommand(ExecuteSwitchCameraAsync);
        ExitCommand = new RelayCommand(() => Application.Current.Shutdown());
        AboutCommand = new RelayCommand(ExecuteAbout);

        _statsTimer = new System.Timers.Timer(500);
        _statsTimer.Elapsed += (_, _) => UpdateStatsDisplay();
        _statsTimer.AutoReset = true;

        _reconnectTimer = new System.Timers.Timer(Settings.ReconnectDelayMs);
        _reconnectTimer.Elapsed += async (_, _) => await AttemptReconnectAsync();
        _reconnectTimer.AutoReset = false;

        InitializeVideoBitmap(1920, 1080);
    }

    private async Task ExecuteScanAsync()
    {
        IsScanning = true;
        StatusMessage = "Scanning for devices...";

        try
        {
            var devices = await _networkClient.DiscoverDevicesAsync();
            _ = Application.Current.Dispatcher.BeginInvoke(() =>
            {
                DiscoveredDevices.Clear();
                foreach (var device in devices)
                {
                    DiscoveredDevices.Add(device);
                }
            });
            StatusMessage = devices.Count > 0
                ? $"Found {devices.Count} device(s)"
                : "No devices found. Try manual connection.";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Scan error: {ex.Message}";
        }
        finally
        {
            IsScanning = false;
        }
    }

    private async Task ExecuteConnectAsync()
    {
        if (_networkClient.IsConnected)
        {
            ExecuteDisconnect();
            return;
        }

        if (string.IsNullOrWhiteSpace(HostAddress))
        {
            StatusMessage = "Please enter an IP address";
            MessageBox.Show(
                "Please enter the iPhone's IP address.\n\nFind it in the RifatCam Pro iOS app.",
                "No IP Address",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            return;
        }

        Settings.HostAddress = HostAddress;
        Settings.Port = Port;
        Settings.Password = Password;
        Settings.Protocol = SelectedProtocol;
        Settings.Resolution = SelectedResolution;
        Settings.TargetFps = SelectedFps;
        Settings.AutoReconnect = AutoReconnect;

        _settingsManager.Save();
        StatusMessage = $"Connecting to {HostAddress}:{Port}...";

        try
        {
            var success = await _networkClient.ConnectAsync(Settings);

            if (success)
            {
                _statsTimer.Start();
                _settingsManager.SetLastConnectedDevice(HostAddress, Port);
                StatusMessage = "Connected! Streaming...";
            }
            else
            {
                StatusMessage = "Connection failed";
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Error: {ex.Message}";
            MessageBox.Show(
                $"Connection failed:\n\n{ex.Message}",
                "Connection Error",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void ExecuteDisconnect()
    {
        _reconnectTimer.Stop();
        _statsTimer.Stop();
        _networkClient.Disconnect();
        StatusMessage = "Disconnected";
        ConnectionStatusText = "Disconnected";
        BitrateText = "0 kbps";
        LatencyText = "0 ms";
        FpsText = "0 FPS";
    }

    private void ExecuteToggleVirtualCamera()
    {
        if (_virtualCamera.IsActive)
        {
            _virtualCamera.Stop();
        }
        else
        {
            if (!_virtualCamera.IsVirtualCameraAvailable())
            {
                MessageBox.Show(
                    "No virtual camera software found.\n\n" +
                    "Please install one of the following:\n" +
                    "\u2022 OBS Studio (with virtual camera)\n" +
                    "\u2022 Any DirectShow virtual camera driver\n\n" +
                    "The video will still stream to the preview window.",
                    "Virtual Camera Not Available",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            var res = GetResolutionFromEnum(SelectedResolution);
            _virtualCamera.Start(res.width, res.height, SelectedFps);
        }
    }

    private async Task ExecuteToggleTorchAsync()
    {
        if (!_networkClient.IsConnected)
        {
            StatusMessage = "Not connected to a device";
            return;
        }
        TorchEnabled = !TorchEnabled;
        Settings.UseTorch = TorchEnabled;
        await _networkClient.SendTorchCommandAsync(TorchEnabled);
        StatusMessage = TorchEnabled ? "Torch ON" : "Torch OFF";
    }

    private async Task ExecuteSwitchCameraAsync()
    {
        if (!_networkClient.IsConnected)
        {
            StatusMessage = "Not connected to a device";
            return;
        }
        await _networkClient.SendSwitchCameraCommandAsync();
        StatusMessage = "Camera switch requested";
    }

    private static void ExecuteAbout()
    {
        MessageBox.Show(
            "RifatCam Pro v1.0.0\n\n" +
            "Professional iPhone-to-PC camera streaming client.\n" +
            "Use your iPhone as a high-quality webcam for\n" +
            "OBS, Zoom, Teams, Discord, Google Meet, and more.",
            "About RifatCam Pro",
            MessageBoxButton.OK,
            MessageBoxImage.Information);
    }

    private void OnFrameReceived(object? sender, byte[] frameData)
    {
        try
        {
            if (IsVirtualCameraRunning)
            {
                var res = GetResolutionFromEnum(SelectedResolution);
                _virtualCamera.PushFrame(frameData, res.width, res.height);
            }

            Application.Current.Dispatcher.BeginInvoke(() =>
            {
                try
                {
                    using var ms = new MemoryStream(frameData);
                    var decoder = new JpegBitmapDecoder(ms, BitmapCreateOptions.PreservePixelFormat,
                        BitmapCacheOption.OnLoad);
                    var frame = decoder.Frames[0];

                    var wb = VideoFrame;
                    if (wb == null || wb.PixelWidth != frame.PixelWidth || wb.PixelHeight != frame.PixelHeight)
                    {
                        wb = new WriteableBitmap(frame.PixelWidth, frame.PixelHeight,
                            96, 96, PixelFormats.Bgr24, null);
                        VideoFrame = wb;
                    }

                    wb.Lock();
                    var stride = (frame.PixelWidth * frame.Format.BitsPerPixel + 7) / 8;
                    var pixels = new byte[stride * frame.PixelHeight];
                    frame.CopyPixels(pixels, stride, 0);
                    wb.WritePixels(new Int32Rect(0, 0, frame.PixelWidth, frame.PixelHeight), pixels, stride, 0);
                    wb.Unlock();
                }
                catch { }
            });

            _lastFrameTime = DateTime.Now;
        }
        catch { }
    }

    private void OnStatsUpdated(object? sender, StreamStats stats)
    {
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            Stats = stats;
            BitrateText = $"{stats.BitrateKbps:F0} kbps";
            FpsText = $"{stats.CurrentFps:F0} FPS";
            LatencyText = $"{stats.LatencyMs:F0} ms";
        });
    }

    private void OnStatusChanged(object? sender, DeviceStatus status)
    {
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            Status = status;
            ConnectionStatusText = status switch
            {
                DeviceStatus.Disconnected => "Disconnected",
                DeviceStatus.Connecting => "Connecting...",
                DeviceStatus.Authenticating => "Authenticating...",
                DeviceStatus.Connected => "Connected",
                DeviceStatus.Streaming => "Streaming",
                DeviceStatus.Error => "Error",
                _ => "Unknown"
            };

            if (status == DeviceStatus.Disconnected && AutoReconnect && Settings.HostAddress.Length > 0)
            {
                _reconnectTimer.Start();
            }
        });
    }

    private void OnErrorOccurred(object? sender, string error)
    {
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            StatusMessage = error;
            ConnectionStatusText = $"Error: {error}";
        });
    }

    private void OnVirtualCameraStateChanged(object? sender, EventArgs e)
    {
        Application.Current.Dispatcher.BeginInvoke(() =>
        {
            IsVirtualCameraRunning = _virtualCamera.IsActive;
            VirtualCameraButtonText = _virtualCamera.IsActive ? "Stop Virtual Camera" : "Start Virtual Camera";
        });
    }

    private void UpdateStatsDisplay()
    {
        var elapsed = (DateTime.Now - _lastFrameTime).TotalSeconds;
        if (elapsed > 5 && Status == DeviceStatus.Streaming)
        {
            Application.Current.Dispatcher.BeginInvoke(() =>
            {
                FpsText = "0 FPS";
                StatusMessage = "No frames received";
            });
        }
    }

    private async Task AttemptReconnectAsync()
    {
        if (_networkClient.IsConnected) return;

        _ = Application.Current.Dispatcher.BeginInvoke(() => StatusMessage = "Attempting reconnect...");

        var success = await _networkClient.ConnectAsync(Settings);
        if (success)
        {
            _statsTimer.Start();
        }
    }

    private void InitializeVideoBitmap(int width, int height)
    {
        Application.Current.Dispatcher.Invoke(() =>
        {
            VideoFrame = new WriteableBitmap(width, height, 96, 96,
                PixelFormats.Bgr24, null);
        });
    }

    private static (int width, int height) GetResolutionFromEnum(StreamResolution res) => res switch
    {
        StreamResolution.R640x480 => (640, 480),
        StreamResolution.R1280x720 => (1280, 720),
        StreamResolution.R1920x1080 => (1920, 1080),
        StreamResolution.R2560x1440 => (2560, 1440),
        StreamResolution.R3840x2160 => (3840, 2160),
        _ => (1920, 1080)
    };

    public void Dispose()
    {
        _networkClient.FrameReceived -= OnFrameReceived;
        _networkClient.StatsUpdated -= OnStatsUpdated;
        _networkClient.StatusChanged -= OnStatusChanged;
        _networkClient.ErrorOccurred -= OnErrorOccurred;
        _virtualCamera.StateChanged -= OnVirtualCameraStateChanged;

        _statsTimer.Stop();
        _statsTimer.Dispose();
        _reconnectTimer.Stop();
        _reconnectTimer.Dispose();

        _networkClient.Dispose();
        _virtualCamera.Dispose();

        GC.SuppressFinalize(this);
    }
}
