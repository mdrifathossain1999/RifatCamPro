using System.IO;
using System.Text.Json;
using RifatCamPro.Client.Models;

namespace RifatCamPro.Client.Services;

public class SettingsManager
{
    private static readonly string SettingsDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "RifatCamPro");

    private static readonly string SettingsFile = Path.Combine(SettingsDir, "settings.json");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public ConnectionSettings Settings { get; private set; } = new();

    public void Load()
    {
        try
        {
            if (File.Exists(SettingsFile))
            {
                var json = File.ReadAllText(SettingsFile);
                var loaded = JsonSerializer.Deserialize<ConnectionSettings>(json, JsonOptions);
                if (loaded != null)
                    Settings = loaded;
            }
        }
        catch
        {
            Settings = new ConnectionSettings();
        }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(SettingsDir);
            var json = JsonSerializer.Serialize(Settings, JsonOptions);
            File.WriteAllText(SettingsFile, json);
        }
        catch
        {
            // Silently fail - settings are non-critical
        }
    }

    public void SetLastConnectedDevice(string address, int port)
    {
        Settings.HostAddress = address;
        Settings.Port = port;
        Save();
    }
}
