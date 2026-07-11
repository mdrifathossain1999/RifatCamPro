using System.Buffers.Binary;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using RifatCamPro.Client.Models;

namespace RifatCamPro.Client.Services;

public class NetworkClient : IDisposable
{
    private TcpClient? _tcpClient;
    private NetworkStream? _networkStream;
    private CancellationTokenSource? _cts;
    private Task? _receiveTask;
    private string? _mjpegBoundary;

    private const string DiscoveryBroadcastAddress = "255.255.255.255";
    private const int DiscoveryPort = 49383;
    private const int HandshakeTimeoutMs = 5000;
    private const int ReceiveBufferSize = 1024 * 1024;

    public event EventHandler<byte[]>? FrameReceived;
    public event EventHandler<StreamStats>? StatsUpdated;
    public event EventHandler<DeviceStatus>? StatusChanged;
    public event EventHandler<string>? ErrorOccurred;

    public bool IsConnected => _tcpClient?.Connected ?? false;
    public StreamProtocol CurrentProtocol { get; private set; }

    public async Task<List<DiscoveredDevice>> DiscoverDevicesAsync(CancellationToken ct = default)
    {
        var devices = new List<DiscoveredDevice>();

        try
        {
            using var udp = new UdpClient();
            udp.EnableBroadcast = true;
            udp.Client.ReceiveTimeout = 3000;

            var discoveryPacket = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
            {
                type = "discover",
                app = "RifatCamPro",
                version = "1.0"
            }));

            await udp.SendAsync(discoveryPacket, discoveryPacket.Length,
                new IPEndPoint(IPAddress.Broadcast, DiscoveryPort));

            var deadline = DateTime.UtcNow.AddSeconds(3);

            while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
            {
                try
                {
                    var result = await udp.ReceiveAsync(ct);
                    var json = Encoding.UTF8.GetString(result.Buffer);
                    var info = JsonSerializer.Deserialize<JsonElement>(json);

                    var device = new DiscoveredDevice
                    {
                        Name = info.GetProperty("name").GetString() ?? "Unknown",
                        HostName = info.TryGetProperty("hostname", out var hn) ? hn.GetString() ?? "" : "",
                        Address = result.RemoteEndPoint.Address,
                        Port = info.TryGetProperty("port", out var pt) ? pt.GetInt32() : 4747,
                        DeviceId = info.TryGetProperty("deviceId", out var did) ? did.GetString() ?? "" : "",
                        Model = info.TryGetProperty("model", out var md) ? md.GetString() ?? "" : "",
                        OsVersion = info.TryGetProperty("osVersion", out var os) ? os.GetString() ?? "" : "",
                        IsSecure = info.TryGetProperty("secure", out var sec) && sec.GetBoolean()
                    };

                    if (!devices.Any(d => d.DeviceId == device.DeviceId))
                        devices.Add(device);
                }
                catch (SocketException)
                {
                    break;
                }
            }
        }
        catch (Exception ex)
        {
            ErrorOccurred?.Invoke(this, $"Discovery error: {ex.Message}");
        }

        return devices;
    }

    public async Task<bool> ConnectAsync(ConnectionSettings settings, CancellationToken ct = default)
    {
        try
        {
            StatusChanged?.Invoke(this, DeviceStatus.Connecting);
            _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);

            _tcpClient = new TcpClient
            {
                ReceiveBufferSize = ReceiveBufferSize,
                SendBufferSize = 65536,
                NoDelay = true
            };

            if (!IPAddress.TryParse(settings.HostAddress, out var ip))
            {
                var addresses = await Dns.GetHostAddressesAsync(settings.HostAddress, ct);
                ip = addresses.FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
                if (ip == null)
                {
                    ErrorOccurred?.Invoke(this, $"Could not resolve host: {settings.HostAddress}");
                    StatusChanged?.Invoke(this, DeviceStatus.Error);
                    return false;
                }
            }

            var connectTask = _tcpClient.ConnectAsync(ip, settings.Port, ct).AsTask();
            if (await Task.WhenAny(connectTask, Task.Delay(HandshakeTimeoutMs, ct)) != connectTask)
            {
                ErrorOccurred?.Invoke(this, "Connection timed out");
                StatusChanged?.Invoke(this, DeviceStatus.Error);
                return false;
            }

            await connectTask;
            _networkStream = _tcpClient.GetStream();

            if (settings.Protocol == StreamProtocol.Mjpeg)
            {
                if (!await ConnectMjpegAsync(settings, ct))
                {
                    return false;
                }
            }
            else
            {
                StatusChanged?.Invoke(this, DeviceStatus.Authenticating);

                if (!await PerformHandshakeAsync(settings, ct))
                {
                    ErrorOccurred?.Invoke(this, "Authentication failed");
                    StatusChanged?.Invoke(this, DeviceStatus.Error);
                    return false;
                }

                await SendSettingsAsync(settings, ct);
            }

            CurrentProtocol = settings.Protocol;
            StatusChanged?.Invoke(this, DeviceStatus.Connected);

            _receiveTask = Task.Run(() => ReceiveLoopAsync(settings.Protocol, _cts.Token), _cts.Token);

            StatusChanged?.Invoke(this, DeviceStatus.Streaming);
            return true;
        }
        catch (Exception ex)
        {
            ErrorOccurred?.Invoke(this, $"Connection error: {ex.Message}");
            StatusChanged?.Invoke(this, DeviceStatus.Error);
            return false;
        }
    }

    private async Task<bool> ConnectMjpegAsync(ConnectionSettings settings, CancellationToken ct)
    {
        if (_networkStream == null) return false;

        StatusChanged?.Invoke(this, DeviceStatus.Authenticating);

        var paths = new[] { "/mjpeg", "/" };
        foreach (var path in paths)
        {
            if (ct.IsCancellationRequested) return false;

            var request = $"GET {path} HTTP/1.1\r\nHost: {settings.HostAddress}:{settings.Port}\r\nConnection: keep-alive\r\n\r\n";
            var requestBytes = Encoding.UTF8.GetBytes(request);
            await _networkStream.WriteAsync(requestBytes, ct);

            var statusLine = await ReadLineAsync(ct);
            if (string.IsNullOrEmpty(statusLine))
            {
                ErrorOccurred?.Invoke(this, "No response from server. Is the iOS app running?");
                StatusChanged?.Invoke(this, DeviceStatus.Error);
                return false;
            }

            if (statusLine.Contains("200"))
            {
                return await ParseMjpegHeadersAsync(ct);
            }

            while (!ct.IsCancellationRequested)
            {
                var line = await ReadLineAsync(ct);
                if (string.IsNullOrEmpty(line)) break;
            }
        }

        ErrorOccurred?.Invoke(this, "No MJPEG stream found at /mjpeg or /");
        StatusChanged?.Invoke(this, DeviceStatus.Error);
        return false;
    }

    private async Task<bool> ParseMjpegHeadersAsync(CancellationToken ct)
    {
        string? boundary = null;

        while (!ct.IsCancellationRequested)
        {
            var line = await ReadLineAsync(ct);
            if (string.IsNullOrEmpty(line)) break;

            if (line.StartsWith("Content-Type:", StringComparison.OrdinalIgnoreCase) &&
                line.Contains("multipart/x-mixed-replace", StringComparison.OrdinalIgnoreCase))
            {
                var idx = line.IndexOf("boundary=", StringComparison.OrdinalIgnoreCase);
                if (idx >= 0)
                {
                    boundary = line.Substring(idx + 9).Trim().Trim('"');
                }
            }
        }

        if (string.IsNullOrEmpty(boundary))
        {
            ErrorOccurred?.Invoke(this, "Invalid MJPEG stream: no multipart boundary found");
            StatusChanged?.Invoke(this, DeviceStatus.Error);
            return false;
        }

        _mjpegBoundary = boundary;
        return true;
    }

    private async Task<string?> ReadLineAsync(CancellationToken ct)
    {
        if (_networkStream == null) return null;

        var ms = new MemoryStream();
        var singleByte = new byte[1];

        while (!ct.IsCancellationRequested)
        {
            int read;
            try
            {
                read = await _networkStream.ReadAsync(singleByte, ct);
            }
            catch
            {
                return ms.Length > 0 ? Encoding.UTF8.GetString(ms.ToArray()) : null;
            }

            if (read == 0)
            {
                return ms.Length > 0 ? Encoding.UTF8.GetString(ms.ToArray()) : null;
            }

            ms.Write(singleByte, 0, 1);

            if (ms.Length >= 2)
            {
                var arr = ms.ToArray();
                if (arr[^2] == '\r' && arr[^1] == '\n')
                {
                    return Encoding.UTF8.GetString(arr, 0, arr.Length - 2);
                }
            }
        }

        return null;
    }

    private async Task<bool> PerformHandshakeAsync(ConnectionSettings settings, CancellationToken ct)
    {
        if (_networkStream == null) return false;

        var challenge = new byte[32];
        await _networkStream.ReadExactlyAsync(challenge, ct);

        var responseBytes = new byte[64];
        Array.Copy(challenge, responseBytes, 32);

        if (!string.IsNullOrEmpty(settings.Password))
        {
            var passwordBytes = Encoding.UTF8.GetBytes(settings.Password);
            using var hmac = new HMACSHA256(passwordBytes);
            var hash = hmac.ComputeHash(challenge);
            Array.Copy(hash, 0, responseBytes, 32, 32);
        }
        else
        {
            Array.Copy(challenge, 0, responseBytes, 32, 32);
        }

        await _networkStream.WriteAsync(responseBytes, ct);

        var statusBuffer = new byte[16];
        var read = await _networkStream.ReadAsync(statusBuffer, ct);
        var status = Encoding.UTF8.GetString(statusBuffer, 0, read).TrimEnd('\0');

        return status == "OK";
    }

    private async Task SendSettingsAsync(ConnectionSettings settings, CancellationToken ct)
    {
        if (_networkStream == null) return;

        var config = new
        {
            protocol = settings.Protocol.ToString().ToLower(),
            width = GetResolutionWidth(settings.Resolution),
            height = GetResolutionHeight(settings.Resolution),
            fps = settings.TargetFps,
            torch = settings.UseTorch
        };

        var json = JsonSerializer.Serialize(config);
        var lengthBytes = BitConverter.GetBytes(BinaryPrimitives.ReverseEndianness((uint)Encoding.UTF8.GetByteCount(json)));
        await _networkStream.WriteAsync(lengthBytes, ct);
        await _networkStream.WriteAsync(Encoding.UTF8.GetBytes(json), ct);
    }

    private async Task SendCommandAsync(string command, CancellationToken ct)
    {
        if (_networkStream == null) return;

        var json = JsonSerializer.Serialize(new { command });
        var lengthBytes = BitConverter.GetBytes(BinaryPrimitives.ReverseEndianness((uint)Encoding.UTF8.GetByteCount(json)));
        await _networkStream.WriteAsync(lengthBytes, ct);
        await _networkStream.WriteAsync(Encoding.UTF8.GetBytes(json), ct);
    }

    public Task SendTorchCommandAsync(bool enabled, CancellationToken ct = default)
        => SendCommandAsync(enabled ? "torch_on" : "torch_off", ct);

    public Task SendSwitchCameraCommandAsync(CancellationToken ct = default)
        => SendCommandAsync("switch_camera", ct);

    public Task SendDisconnectCommandAsync(CancellationToken ct = default)
        => SendCommandAsync("disconnect", ct);

    private async Task ReceiveLoopAsync(StreamProtocol protocol, CancellationToken ct)
    {
        if (_networkStream == null) return;

        var stats = new StreamStats { ConnectedAt = DateTime.Now };
        var sw = Stopwatch.StartNew();
        var lastStatsTime = sw.ElapsedMilliseconds;
        var intervalFrameCount = 0;
        var intervalBytes = 0L;
        var fpsAccum = new Queue<double>();

        try
        {
            while (!ct.IsCancellationRequested && _tcpClient?.Connected == true)
            {
                byte[]? frameData = null;
                int bytesRead = 0;

                if (protocol == StreamProtocol.Mjpeg)
                {
                    var result = await ReceiveNextMjpegFrameAsync(ct);
                    if (result != null)
                    {
                        frameData = result;
                        bytesRead = result.Length;
                    }
                }
                else
                {
                    var (nalData, nalBytesRead) = await ReceiveH264NalAsync(_networkStream, ct);
                    frameData = nalData;
                    bytesRead = nalBytesRead;
                }

                if (frameData != null)
                {
                    stats.FramesReceived++;
                    intervalFrameCount++;
                    intervalBytes += bytesRead;
                    FrameReceived?.Invoke(this, frameData);
                }

                var now = sw.ElapsedMilliseconds;
                if (now - lastStatsTime >= 1000)
                {
                    var instantFps = intervalFrameCount * 1000.0 / Math.Max(1, now - lastStatsTime);
                    fpsAccum.Enqueue(instantFps);
                    if (fpsAccum.Count > 5) fpsAccum.Dequeue();

                    stats.CurrentFps = Math.Round(instantFps, 1);
                    stats.AverageFps = Math.Round(fpsAccum.Average(), 1);
                    stats.BitrateKbps = Math.Round(intervalBytes * 8.0 / 1000.0 / Math.Max(1, (now - lastStatsTime) / 1000.0), 1);
                    stats.TotalBytesReceived += intervalBytes;

                    StatsUpdated?.Invoke(this, stats);

                    intervalFrameCount = 0;
                    intervalBytes = 0;
                    lastStatsTime = now;
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            ErrorOccurred?.Invoke(this, $"Receive error: {ex.Message}");
        }
    }

    private async Task<byte[]?> ReceiveNextMjpegFrameAsync(CancellationToken ct)
    {
        if (_networkStream == null || _mjpegBoundary == null) return null;

        try
        {
            var line = await ReadLineAsync(ct);
            if (line == null) return null;

            while (!ct.IsCancellationRequested)
            {
                line = await ReadLineAsync(ct);
                if (line == null) return null;
                if (string.IsNullOrEmpty(line)) break;
            }

            var boundaryMarker = Encoding.UTF8.GetBytes($"\r\n--{_mjpegBoundary}");
            var readBuffer = new byte[64 * 1024];
            var accumulator = new MemoryStream(256 * 1024);
            var totalRead = 0;

            while (!ct.IsCancellationRequested)
            {
                var bytesRead = await _networkStream.ReadAsync(readBuffer, ct);
                if (bytesRead == 0) break;

                var prevLen = totalRead;
                accumulator.Write(readBuffer, 0, bytesRead);
                totalRead += bytesRead;

                var buf = accumulator.GetBuffer();
                var searchStart = Math.Max(0, prevLen - boundaryMarker.Length + 1);

                for (var i = searchStart; i <= totalRead - boundaryMarker.Length; i++)
                {
                    if (buf.AsSpan(i, boundaryMarker.Length).SequenceEqual(boundaryMarker))
                    {
                        var frame = new byte[i];
                        Buffer.BlockCopy(buf, 0, frame, 0, i);
                        return frame;
                    }
                }

                if (totalRead > 10 * 1024 * 1024)
                {
                    return accumulator.ToArray();
                }
            }

            return totalRead > 0 ? accumulator.ToArray() : null;
        }
        catch (OperationCanceledException) { }
        catch { }

        return null;
    }

    private static async Task<(byte[]? data, int bytesRead)> ReceiveH264NalAsync(NetworkStream stream, CancellationToken ct)
    {
        var lengthBuffer = new byte[4];
        int totalRead = 0;
        while (totalRead < 4)
        {
            var read = await stream.ReadAsync(lengthBuffer.AsMemory(totalRead, 4 - totalRead), ct);
            if (read == 0) return (null, 0);
            totalRead += read;
        }

        var nalLength = BinaryPrimitives.ReverseEndianness(BitConverter.ToUInt32(lengthBuffer));

        if (nalLength == 0 || nalLength > 10 * 1024 * 1024)
            return (null, 0);

        var nalData = new byte[nalLength];
        totalRead = 0;
        while (totalRead < (int)nalLength)
        {
            var read = await stream.ReadAsync(nalData.AsMemory(totalRead, (int)nalLength - totalRead), ct);
            if (read == 0) return (null, 0);
            totalRead += read;
        }

        return (nalData, (int)nalLength + 4);
    }

    public void Disconnect()
    {
        _cts?.Cancel();

        try { _networkStream?.Close(); } catch { }
        try { _tcpClient?.Close(); } catch { }

        _networkStream = null;
        _tcpClient = null;
        _mjpegBoundary = null;

        StatusChanged?.Invoke(this, DeviceStatus.Disconnected);
    }

    public void Dispose()
    {
        Disconnect();
        _cts?.Dispose();
        GC.SuppressFinalize(this);
    }

    private static int GetResolutionWidth(StreamResolution res) => res switch
    {
        StreamResolution.R640x480 => 640,
        StreamResolution.R1280x720 => 1280,
        StreamResolution.R1920x1080 => 1920,
        StreamResolution.R2560x1440 => 2560,
        StreamResolution.R3840x2160 => 3840,
        _ => 1920
    };

    private static int GetResolutionHeight(StreamResolution res) => res switch
    {
        StreamResolution.R640x480 => 480,
        StreamResolution.R1280x720 => 720,
        StreamResolution.R1920x1080 => 1080,
        StreamResolution.R2560x1440 => 1440,
        StreamResolution.R3840x2160 => 2160,
        _ => 1080
    };

    private void ErrorChanged(string message)
    {
        ErrorOccurred?.Invoke(this, message);
        StatusChanged?.Invoke(this, DeviceStatus.Error);
    }
}
