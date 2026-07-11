using System.Net;
using CommunityToolkit.Mvvm.ComponentModel;

namespace RifatCamPro.Client.Models;

public enum StreamProtocol
{
    Mjpeg,
    H264
}

public enum StreamResolution
{
    R640x480,
    R1280x720,
    R1920x1080,
    R2560x1440,
    R3840x2160
}

public enum DeviceStatus
{
    Disconnected,
    Connecting,
    Authenticating,
    Connected,
    Streaming,
    Error
}

public partial class DiscoveredDevice : ObservableObject
{
    [ObservableProperty]
    private string _name = string.Empty;

    [ObservableProperty]
    private string _hostName = string.Empty;

    [ObservableProperty]
    private IPAddress? _address;

    [ObservableProperty]
    private int _port;

    [ObservableProperty]
    private string _deviceId = string.Empty;

    [ObservableProperty]
    private string _model = string.Empty;

    [ObservableProperty]
    private string _osVersion = string.Empty;

    [ObservableProperty]
    private bool _isSecure;

    public string DisplayName => string.IsNullOrEmpty(Name) ? HostName : Name;
    public string Endpoint => Address != null ? $"{Address}:{Port}" : HostName;
}

public partial class ConnectionSettings : ObservableObject
{
    [ObservableProperty]
    private string _hostAddress = string.Empty;

    [ObservableProperty]
    private int _port = 4747;

    [ObservableProperty]
    private string _password = string.Empty;

    [ObservableProperty]
    private StreamProtocol _protocol = StreamProtocol.Mjpeg;

    [ObservableProperty]
    private StreamResolution _resolution = StreamResolution.R1920x1080;

    [ObservableProperty]
    private int _targetFps = 30;

    [ObservableProperty]
    private bool _autoReconnect = true;

    [ObservableProperty]
    private int _reconnectDelayMs = 3000;

    [ObservableProperty]
    private bool _enableAudio = false;

    [ObservableProperty]
    private bool _useTorch = false;
}

public partial class StreamStats : ObservableObject
{
    [ObservableProperty]
    private double _currentFps;

    [ObservableProperty]
    private double _averageFps;

    [ObservableProperty]
    private double _bitrateKbps;

    [ObservableProperty]
    private double _latencyMs;

    [ObservableProperty]
    private long _totalBytesReceived;

    [ObservableProperty]
    private int _framesReceived;

    [ObservableProperty]
    private int _framesDropped;

    [ObservableProperty]
    private int _width;

    [ObservableProperty]
    private int _height;

    [ObservableProperty]
    private DateTime _connectedAt;

    public TimeSpan Uptime => DateTime.Now - ConnectedAt;
}
