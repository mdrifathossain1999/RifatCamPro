using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace RifatCamPro.Client.Services;

public class VirtualCamera : IDisposable
{
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);

    private readonly object _lock = new();
    private Thread? _frameThread;
    private CancellationTokenSource? _cts;
    private bool _isActive;

    private int _width = 1920;
    private int _height = 1080;
    private int _fps = 30;
    private byte[]? _latestFrame;
    private bool _frameUpdated;

    public bool IsActive => _isActive;
    public int Width => _width;
    public int Height => _height;
    public int Fps => _fps;

    public event EventHandler? StateChanged;

    public bool IsVirtualCameraAvailable()
    {
        try
        {
            return IsOBSVirtualCameraAvailable() || IsDirectShowVirtualCameraAvailable();
        }
        catch
        {
            return false;
        }
    }

    private static bool IsOBSVirtualCameraAvailable()
    {
        var obsPaths = new[]
        {
            @"C:\Program Files\obs-studio\bin\64bit\obs-virtualcam.dll",
            @"C:\Program Files (x86)\obs-studio\bin\32bit\obs-virtualcam.dll",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                @"obs-studio\virtual-cam")
        };

        return obsPaths.Any(File.Exists);
    }

    private static bool IsDirectShowVirtualCameraAvailable()
    {
        try
        {
            var regKey = Microsoft.Win32.Registry.ClassesRoot.OpenSubKey("CLSID");
            if (regKey != null)
            {
                foreach (var subKeyName in regKey.GetSubKeyNames())
                {
                    var nameKey = regKey.OpenSubKey(subKeyName + @"\FriendlyName");
                    var name = nameKey?.GetValue("")?.ToString() ?? "";
                    if (name.Contains("Virtual", StringComparison.OrdinalIgnoreCase) ||
                        name.Contains("OBS", StringComparison.OrdinalIgnoreCase))
                    {
                        regKey.Close();
                        return true;
                    }
                }
                regKey.Close();
            }
        }
        catch { }

        return false;
    }

    public bool Start(int width = 1920, int height = 1080, int fps = 30)
    {
        if (_isActive) return true;

        lock (_lock)
        {
            _width = width;
            _height = height;
            _fps = fps;
            _cts = new CancellationTokenSource();
            _isActive = true;

            _frameThread = new Thread(FrameLoop)
            {
                IsBackground = true,
                Name = "VirtualCamera-FrameLoop"
            };
            _frameThread.Start(_cts.Token);

            StateChanged?.Invoke(this, EventArgs.Empty);
            return true;
        }
    }

    public void Stop()
    {
        if (!_isActive) return;

        lock (_lock)
        {
            _cts?.Cancel();
            _frameThread?.Join(TimeSpan.FromSeconds(2));
            _isActive = false;
            _latestFrame = null;
            _frameUpdated = false;

            StateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public void PushFrame(byte[] frameData, int width, int height)
    {
        if (!_isActive) return;

        lock (_lock)
        {
            _latestFrame = frameData;
            _width = width;
            _height = height;
            _frameUpdated = true;
            Monitor.PulseAll(_lock);
        }
    }

    public void PushFrame(byte[] rgbData, int width, int height, int stride)
    {
        if (!_isActive) return;

        var converted = ConvertRgbToDib(rgbData, width, height, stride);

        lock (_lock)
        {
            _latestFrame = converted;
            _width = width;
            _height = height;
            _frameUpdated = true;
            Monitor.PulseAll(_lock);
        }
    }

    public void PushFrame(IntPtr dibHeader, int size)
    {
        if (!_isActive) return;

        var data = new byte[size];
        Marshal.Copy(dibHeader, data, 0, size);

        lock (_lock)
        {
            _latestFrame = data;
            _frameUpdated = true;
            Monitor.PulseAll(_lock);
        }
    }

    private void FrameLoop(object? state)
    {
        var ct = (CancellationToken)state!;
        var frameInterval = TimeSpan.FromMilliseconds(1000.0 / _fps);
        var sw = Stopwatch.StartNew();
        var virtualCam = TryCreateVirtualCamSink();

        try
        {
            while (!ct.IsCancellationRequested)
            {
                var frameStart = sw.Elapsed;
                byte[]? frame = null;

                lock (_lock)
                {
                    while (!_frameUpdated && !ct.IsCancellationRequested)
                    {
                        Monitor.Wait(_lock, 100);
                    }

                    if (_frameUpdated && _latestFrame != null)
                    {
                        frame = new byte[_latestFrame.Length];
                        Buffer.BlockCopy(_latestFrame, 0, frame, 0, _latestFrame.Length);
                        _frameUpdated = false;
                    }
                }

                if (frame != null && virtualCam != null)
                {
                    virtualCam.PushFrame(frame, _width, _height);
                }

                var elapsed = sw.Elapsed - frameStart;
                var sleepTime = frameInterval - elapsed;
                if (sleepTime > TimeSpan.Zero)
                {
                    Thread.Sleep(sleepTime);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (ThreadAbortException) { }
        finally
        {
            virtualCam?.Dispose();
        }
    }

    private IVirtualCamSink? TryCreateVirtualCamSink()
    {
        try
        {
            if (IsOBSVirtualCameraAvailable())
            {
                return new ObsVirtualCamSink();
            }
        }
        catch { }

        try
        {
            return new SharedMemoryVirtualCamSink(_width, _height, _fps);
        }
        catch { }

        Console.WriteLine("[VirtualCamera] No virtual camera sink available. Install OBS Studio or a DirectShow virtual camera driver.");
        return null;
    }

    private static byte[] ConvertRgbToDib(byte[] rgb, int width, int height, int srcStride)
    {
        var bitsPerPixel = 32;
        var stride = ((width * bitsPerPixel + 31) & ~31) / 8;
        var pixelDataSize = stride * height;
        var headerSize = 40;
        var totalSize = headerSize + pixelDataSize;

        var dib = new byte[totalSize];

        // BITMAPINFOHEADER
        dib[0] = 40; // biSize
        WriteLittleEndianInt(dib, 4, width);
        WriteLittleEndianInt(dib, 8, height * -1); // top-down
        WriteLittleEndianShort(dib, 12, 1); // biPlanes
        WriteLittleEndianShort(dib, 14, (short)bitsPerPixel);
        WriteLittleEndianInt(dib, 24, pixelDataSize);

        for (var y = 0; y < height; y++)
        {
            var srcRow = y * srcStride;
            var dstRow = headerSize + y * stride;

            for (var x = 0; x < width; x++)
            {
                var srcIdx = srcRow + x * 3;
                var dstIdx = dstRow + x * 4;

                if (srcIdx + 2 < rgb.Length && dstIdx + 3 < dib.Length)
                {
                    dib[dstIdx] = rgb[srcIdx + 2];     // B
                    dib[dstIdx + 1] = rgb[srcIdx + 1]; // G
                    dib[dstIdx + 2] = rgb[srcIdx];     // R
                    dib[dstIdx + 3] = 255;              // A
                }
            }
        }

        return dib;
    }

    private static void WriteLittleEndianInt(byte[] buffer, int offset, int value)
    {
        buffer[offset] = (byte)(value & 0xFF);
        buffer[offset + 1] = (byte)((value >> 8) & 0xFF);
        buffer[offset + 2] = (byte)((value >> 16) & 0xFF);
        buffer[offset + 3] = (byte)((value >> 24) & 0xFF);
    }

    private static void WriteLittleEndianShort(byte[] buffer, int offset, short value)
    {
        buffer[offset] = (byte)(value & 0xFF);
        buffer[offset + 1] = (byte)((value >> 8) & 0xFF);
    }

    public void Dispose()
    {
        Stop();
        GC.SuppressFinalize(this);
    }

    #region Virtual Camera Sink Interfaces

    private interface IVirtualCamSink : IDisposable
    {
        void PushFrame(byte[] frame, int width, int height);
    }

    private class ObsVirtualCamSink : IVirtualCamSink
    {
        private const string SharedMemoryName = "OBSVirtualCam";
        private System.IO.MemoryMappedFiles.MemoryMappedFile? _mmf;
        private System.IO.MemoryMappedFiles.MemoryMappedViewAccessor? _accessor;

        public ObsVirtualCamSink()
        {
            _mmf = System.IO.MemoryMappedFiles.MemoryMappedFile.CreateOrOpen(
                SharedMemoryName, 1920 * 1080 * 4 + 64);
            _accessor = _mmf.CreateViewAccessor();
        }

        public void PushFrame(byte[] frame, int width, int height)
        {
            if (_accessor == null) return;

            var headerSize = 64;
            var header = new byte[headerSize];

            // Magic: 'OBSVC'
            header[0] = (byte)'O'; header[1] = (byte)'B'; header[2] = (byte)'S';
            header[3] = (byte)'V'; header[4] = (byte)'C';

            // Version
            header[5] = 1;

            // Width (LE)
            header[8] = (byte)(width & 0xFF);
            header[9] = (byte)((width >> 8) & 0xFF);
            header[10] = (byte)((width >> 16) & 0xFF);
            header[11] = (byte)((width >> 24) & 0xFF);

            // Height (LE)
            header[12] = (byte)(height & 0xFF);
            header[13] = (byte)((height >> 8) & 0xFF);
            header[14] = (byte)((height >> 16) & 0xFF);
            header[15] = (byte)((height >> 24) & 0xFF);

            // FourCC BGRA
            header[16] = (byte)'B'; header[17] = (byte)'G';
            header[18] = (byte)'R'; header[19] = (byte)'A';

            _accessor.WriteArray(0, header, 0, header.Length);
            var frameLen = Math.Min(frame.Length, width * height * 4);
            _accessor.WriteArray(headerSize, frame, 0, frameLen);
        }

        public void Dispose()
        {
            _accessor?.Dispose();
            _mmf?.Dispose();
        }
    }

    private class SharedMemoryVirtualCamSink : IVirtualCamSink
    {
        private const string SharedMemName = "RifatCamPro_VirtualCam";
        private System.IO.MemoryMappedFiles.MemoryMappedFile? _mmf;
        private System.IO.MemoryMappedFiles.MemoryMappedViewAccessor? _accessor;
        private readonly int _stride;

        public SharedMemoryVirtualCamSink(int width, int height, int fps)
        {
            _stride = ((width * 4 + 31) & ~31) / 8;
            var totalSize = _stride * height + 128;

            _mmf = System.IO.MemoryMappedFiles.MemoryMappedFile.CreateOrOpen(
                SharedMemName, totalSize);
            _accessor = _mmf.CreateViewAccessor();

            // Write header
            var header = new byte[128];
            header[0] = (byte)'R'; header[1] = (byte)'C'; header[2] = (byte)'P'; header[3] = (byte)'C';

            header[4] = (byte)(width & 0xFF);
            header[5] = (byte)((width >> 8) & 0xFF);
            header[6] = (byte)((width >> 16) & 0xFF);
            header[7] = (byte)((width >> 24) & 0xFF);

            header[8] = (byte)(height & 0xFF);
            header[9] = (byte)((height >> 8) & 0xFF);
            header[10] = (byte)((height >> 16) & 0xFF);
            header[11] = (byte)((height >> 24) & 0xFF);

            header[12] = (byte)fps;
            header[13] = (byte)(_stride & 0xFF);
            header[14] = (byte)((_stride >> 8) & 0xFF);

            _accessor.WriteArray(0, header, 0, 128);
        }

        public void PushFrame(byte[] frame, int width, int height)
        {
            if (_accessor == null) return;
            _accessor.WriteArray(128, frame, 0, Math.Min(frame.Length, _stride * height));
        }

        public void Dispose()
        {
            _accessor?.Dispose();
            _mmf?.Dispose();
        }
    }

    #endregion
}
