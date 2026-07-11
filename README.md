<div align="center">

# RifatCam Pro

### Professional Wireless Webcam Solution

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)]()
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B%20%7C%20Windows%2010%2B%20%7C%20OBS%2028%2B-lightgrey.svg)]()
[![License](https://img.shields.io/badge/license-MIT-green.svg)]()
[![Swift](https://img.shields.io/badge/swift-6.0-orange.svg)]()
[![.NET](https://img.shields.io/badge/.NET-9.0-purple.svg)]()
[![C++](https://img.shields.io/badge/C%2B%2B-17-blue.svg)]()

Turn your iPhone into a high-quality wireless webcam for your PC.

</div>

---

## Table of Contents

- [Features](#features)
- [Screenshots](#screenshots)
- [Requirements](#requirements)
- [Installation](#installation)
  - [iOS App (Xcode)](#ios-app-xcode)
  - [Windows Client (.NET 9)](#windows-client-net-9)
  - [OBS Studio Plugin](#obs-studio-plugin)
- [Usage Guide](#usage-guide)
- [API Documentation](#api-documentation)
- [Architecture](#architecture)
- [Project Structure](#project-structure)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [License](#license)
- [Contributing](#contributing)

---

## Features

### Camera & Streaming

| Feature | Details |
|---------|---------|
| Camera Selection | Front / Rear camera switching |
| Resolutions | 4K (3840x2160), 1080p (1920x1080), 720p (1280x720), 480p (640x480) |
| Frame Rates | 15 / 24 / 25 / 30 / 48 / 50 / 60 FPS |
| Codecs | MJPEG, H.264, HEVC (H.265) |
| HDR Support | Optional HDR capture on supported devices |
| Adaptive Bitrate | Dynamic bitrate adjustment (100 Kbps - 50 Mbps) |
| Ultra Low Latency | Optimized pipeline with hardware encoding |
| Audio Streaming | Built-in microphone capture with noise suppression |
| Camera Controls | Torch, manual focus, zoom (1x-10x), exposure (ISO 25-1600), white balance |

### Network & Discovery

| Feature | Details |
|---------|---------|
| WiFi IP Detection | Automatic local IP address detection |
| Bonjour/mDNS | Automatic device discovery on local network (`_rifatcam._tcp`) |
| QR Code Pairing | Instant connection via QR code scan |
| Password Protection | Optional connection password with SHA-256 hashing |
| Custom Port | Configurable streaming port (default: `4747`) |
| Auto-Reconnect | Automatic reconnection with configurable retry (max 5 attempts) |

### Protocols & Integration

| Feature | Details |
|---------|---------|
| MJPEG Stream | Standard multipart JPEG stream at `/video` |
| H.264/HEVC | Hardware-accelerated NAL unit streaming |
| RTSP Server | Standards-compliant RTSP for universal compatibility |
| REST API | Full HTTP API for remote control (port `4748`) |
| WebSocket | Real-time bidirectional communication |

### Windows Client

| Feature | Details |
|---------|---------|
| Virtual Camera | DirectShow-based virtual camera driver |
| OBS Compatible | Works as an OBS Studio video source |
| Zoom / Teams / Discord | Compatible with any app that accepts a webcam |
| Network Discovery | UDP broadcast + Bonjour device scanning |
| Dark Theme | Native WPF dark mode UI |

### OBS Studio Plugin

| Feature | Details |
|---------|---------|
| Auto-Detect | Automatic MJPEG stream detection from iPhone |
| Low Latency | Direct socket connection with minimal buffering |
| Configurable | IP, port, FPS, password, and auto-reconnect settings |
| Cross-Platform | Builds for Windows (x64) and macOS |

### Security

| Feature | Details |
|---------|---------|
| HTTPS/TLS | Optional TLS encryption for all traffic |
| AES-256-GCM | End-to-end data encryption with authenticated encryption |
| SHA-256 Hashing | Password hashing with random salt per device |
| Session Tokens | Secure token-based authentication (HMAC-SHA256 challenge) |
| CORS | Configurable cross-origin resource sharing |

### UI/UX

| Feature | Details |
|---------|---------|
| Apple-Design Language | Glass materials, blur effects, smooth animations |
| Dark Mode | Full dark mode support with dynamic colors |
| Real-Time Stats | Live FPS, bitrate, latency, and connection monitoring |
| Battery Monitoring | Low battery warnings and thermal state alerts |

---

## Screenshots

> _Screenshots will be added after App Store submission._

| iPhone App | Windows Client | OBS Plugin |
|:----------:|:--------------:|:----------:|
| _Coming soon_ | _Coming soon_ | _Coming soon_ |

---

## Requirements

### iOS App

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Xcode | 16.0+ | 16.2+ |
| Swift | 6.0 | 6.0 |
| iOS Deployment Target | 17.0 | 17.2+ |
| Device | iPhone with camera | iPhone 13 or newer |
| Network | WiFi | 5 GHz WiFi |

### Windows Client

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Windows 10 (1903) | Windows 11 |
| .NET SDK | 9.0 | 9.0.100+ |
| Runtime | .NET 9.0 Desktop Runtime | .NET 9.0 Desktop Runtime |
| RAM | 100 MB | 256 MB |
| Network | WiFi / Ethernet | 5 GHz WiFi or Ethernet |

### OBS Plugin

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| CMake | 3.16+ | 3.28+ |
| C++ Compiler | MSVC 2019+ / Clang 14+ | MSVC 2022 |
| OBS Studio | 28.0+ | 30.0+ |
| Platform | Windows x64 / macOS | Windows x64 |

---

## Installation

### iOS App (Xcode)

```bash
# 1. Clone the repository
git clone https://github.com/rifatcam/RifatCamPro.git
cd RifatCamPro

# 2. Open in Xcode
open RifatCamPro.xcodeproj

# 3. Select your Apple Developer Team in Signing & Capabilities

# 4. Connect your iPhone and select it as the build target

# 5. Build and run (Cmd+R)
```

**Manual Setup:**

1. Open `RifatCamPro.xcodeproj` in Xcode 16+.
2. Navigate to **Signing & Capabilities** and select your development team.
3. Verify the bundle identifier is `com.rifatcam.pro` (or change it to your own).
4. Connect your iPhone via USB or set up wireless debugging.
5. Select your device from the device dropdown and press **Cmd + R** to build and install.

> **Note:** Camera and network permissions are requested automatically on first launch. The app uses the `com.apple.developer.networking.multitask` entitlement for Bonjour discovery.

### Windows Client (.NET 9)

```bash
# 1. Clone the repository
git clone https://github.com/rifatcam/RifatCamPro.git
cd RifatCamPro/WindowsClient

# 2. Build the project
dotnet build -c Release

# 3. Run the application
dotnet run --project RifatCamPro.Client
```

**Or install as a standalone app:**

```bash
# Publish as a self-contained executable
dotnet publish RifatCamPro.Client -c Release -r win-x64 --self-contained -p:PublishSingleFile=true

# The executable will be at:
# RifatCamPro.Client/bin/Release/net9.0-windows/win-x64/publish/RifatCamPro.exe
```

**Prerequisites:**
- Install the [.NET 9.0 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/9.0) if not already present.
- Ensure the OBS Virtual Camera driver is installed if using the virtual camera feature.

### OBS Studio Plugin

```bash
# 1. Clone the repository
git clone https://github.com/rifatcam/RifatCamPro.git
cd RifatCamPro/OBSPlugin

# 2. Create a build directory
mkdir build && cd build

# 3. Configure with CMake (point to your OBS installation)
cmake .. -DCMAKE_PREFIX_PATH="C:/Program Files/libobs" -G "Visual Studio 17 2022" -A x64

# 4. Build
cmake --build . --config Release

# 5. Copy the output plugin file to OBS plugins directory
copy bin\rifatcam-source.dll "C:\Program Files\obs-studio\obs-plugins\64bit\"
```

**CMake Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `CMAKE_PREFIX_PATH` | System | Path to OBS SDK / libobs installation |
| `CMAKE_BUILD_TYPE` | Release | Build type (`Release`, `Debug`) |

The plugin uses [stb_image](https://github.com/nothings/stb) for JPEG decoding, which is fetched automatically via CMake `FetchContent`.

---

## Usage Guide

### Step 1: Connect Your iPhone to WiFi

Ensure your iPhone and PC are on the **same WiFi network**. A 5 GHz network is recommended for the best performance.

### Step 2: Launch the iOS App

Open **RifatCam Pro** on your iPhone. The app will:

1. Detect and display your local IP address.
2. Start the Bonjour service for automatic discovery.
3. Begin listening for connections on port **4747**.

### Step 3: Connect from Windows

You have three options to connect:

#### Option A: QR Code Pairing (Recommended)

1. On the iPhone, tap **Show QR Code** from the home screen.
2. On the Windows client, click **Scan QR** and use your webcam to scan the code.
3. The connection is established instantly.

#### Option B: Manual Connection

1. Note the IP address and port displayed on the iPhone (e.g., `192.168.1.42:4747`).
2. In the Windows client, enter the IP address and port.
3. If password protection is enabled, enter the password.
4. Click **Connect**.

#### Option C: Auto-Discovery

1. The Windows client automatically scans the local network for devices.
2. Discovered devices appear in the device list.
3. Click **Connect** on the desired device.

### Step 4: Configure Stream Settings

On either the iPhone or Windows client, configure:

| Setting | Options | Default |
|---------|---------|---------|
| Resolution | 480p, 720p, 1080p, 4K | 1080p |
| Frame Rate | 15, 24, 30, 60 FPS | 30 FPS |
| Codec | MJPEG, H.264, HEVC | H.264 |
| Bitrate | Adaptive or manual | Adaptive |

### Step 5: Use as a Webcam

Once connected, the virtual camera is available to all applications:

- **OBS Studio:** Add a new **Video Capture Device** source, select **RifatCam Pro** or **OBS Virtual Camera**.
- **Zoom:** Go to Settings > Video > Camera, select **OBS Virtual Camera**.
- **Microsoft Teams:** Go to Settings > Devices > Camera, select the virtual camera.
- **Discord:** Go to Settings > Voice & Video > Camera, select the virtual camera.

### Step 6: OBS Plugin (Alternative)

1. Open OBS Studio.
2. Click **+** under Sources and select **RifatCam Source**.
3. Enter your iPhone's IP address and port (default: `4747`).
4. Optionally enter your connection password.
5. Click **OK**. The stream appears as a low-latency source.

---

## API Documentation

The REST API server runs on port **4748** by default. All responses are JSON.

### Authentication

When password protection is enabled, include the session token in the `Authorization` header:

```
Authorization: Bearer <token>
```

Or use Basic Auth with the API token:

```
Authorization: Basic <base64-encoded token>
```

### Endpoints

#### Health Check

```
GET /api/health
```

**Response:**

```json
{
  "status": "ok",
  "uptime": "1234.5",
  "uptimeSeconds": 1234.5,
  "timestamp": "2026-07-12T10:30:00Z",
  "serverRunning": true,
  "requestCount": 42
}
```

---

#### Device Status

```
GET /api/status
```

**Response:**

```json
{
  "device": {
    "name": "John's iPhone",
    "model": "iPhone",
    "systemVersion": "iOS 18.0",
    "deviceId": "ABC123-DEF456"
  },
  "battery": {
    "level": 0.85,
    "state": "unplugged",
    "isCharging": false
  },
  "streaming": {
    "active": true,
    "codec": "h264",
    "resolution": "1080p",
    "bitrate": 4000000,
    "fps": 30.0
  },
  "server": {
    "apiPort": 4748,
    "uptime": "1234.5",
    "totalRequests": 42,
    "connectedClients": 1
  }
}
```

---

#### Streaming Stats

```
GET /api/streaming
```

**Response:**

```json
{
  "isStreaming": true,
  "bitrate": "4.0",
  "bitrateNumeric": 4000000,
  "fps": "29.9",
  "fpsNumeric": 29.9,
  "framesDropped": 2,
  "totalFrames": 3720,
  "duration": "123.5",
  "durationSeconds": 123.5,
  "codec": "h264",
  "resolution": "1080p",
  "connectionCount": 1
}
```

---

#### Start Streaming

```
POST /api/streaming/start
Content-Type: application/json

{
  "codec": "h264",
  "resolution": "1080p",
  "port": 4747
}
```

| Parameter | Type | Required | Valid Values |
|-----------|------|----------|--------------|
| `codec` | string | No | `h264`, `h265`, `hevc`, `vp8`, `vp9`, `av1` |
| `resolution` | string | No | `480p`, `720p`, `1080p`, `4K` |
| `port` | number | No | `1` - `65535` (default: `4747`) |

**Response:**

```json
{
  "success": true,
  "streaming": true,
  "codec": "h264",
  "resolution": "1080p",
  "port": 4747
}
```

---

#### Stop Streaming

```
POST /api/streaming/stop
```

**Response:**

```json
{
  "success": true,
  "streaming": false
}
```

---

#### Switch Camera

```
POST /api/camera/switch
Content-Type: application/json

{
  "position": "front"
}
```

| Parameter | Type | Valid Values |
|-----------|------|--------------|
| `position` | string | `front`, `back`, `ultra_wide`, `telephoto` |

**Response:**

```json
{
  "success": true,
  "camera": "front",
  "message": "Camera switched to front"
}
```

---

#### Toggle Torch

```
POST /api/camera/torch
Content-Type: application/json

{
  "enabled": true
}
```

**Response:**

```json
{
  "success": true,
  "torch": true
}
```

---

#### Set Zoom

```
POST /api/camera/zoom
Content-Type: application/json

{
  "factor": 2.5
}
```

| Parameter | Type | Range |
|-----------|------|-------|
| `factor` | double | `1.0` - `10.0` |

**Response:**

```json
{
  "success": true,
  "factor": 2.5
}
```

---

#### Get Settings

```
GET /api/settings
```

**Response:**

```json
{
  "resolution": "1080p",
  "codec": "h264",
  "bitrate": 4000,
  "fps": 30,
  "autoExposure": true,
  "autoWhiteBalance": true,
  "audioEnabled": true,
  "videoStabilization": true,
  "zoom": 1.0,
  "sessionPreset": "high"
}
```

---

#### Update Settings

```
POST /api/settings
Content-Type: application/json

{
  "resolution": "720p",
  "fps": 60,
  "bitrate": 8000
}
```

| Setting | Type | Description |
|---------|------|-------------|
| `resolution` | string | `480p`, `720p`, `1080p`, `4K` |
| `codec` | string | `mjpeg`, `h264`, `hevc` |
| `bitrate` | int | Bitrate in Kbps |
| `fps` | int | Frame rate (15-60) |
| `autoExposure` | bool | Enable auto exposure |
| `autoWhiteBalance` | bool | Enable auto white balance |
| `audioEnabled` | bool | Enable/disable audio |
| `videoStabilization` | bool | Enable video stabilization |
| `zoom` | double | Zoom factor (1.0-10.0) |

**Response:**

```json
{
  "success": true,
  "updated": ["fps", "resolution"]
}
```

---

#### Get Devices

```
GET /api/devices
```

**Response:**

```json
{
  "devices": [
    {
      "name": "iPhone Camera",
      "address": "192.168.1.42",
      "port": 4747
    }
  ]
}
```

---

#### CORS Preflight

```
OPTIONS /api/*
```

Returns `204 No Content` with CORS headers. Used by browsers for preflight requests.

---

## Architecture

### iOS App — MVVM + Services

```
┌──────────────────────────────────────────────────────────────────┐
│                         Views (SwiftUI)                          │
│  ┌─────────┐ ┌────────────┐ ┌──────────┐ ┌───────────────────┐  │
│  │HomeView │ │SettingsView│ │PairingView│ │  StreamingView    │  │
│  └────┬────┘ └─────┬──────┘ └─────┬────┘ └────────┬──────────┘  │
├───────┼────────────┼──────────────┼───────────────┼──────────────┤
│       │      ViewModels           │               │              │
│  ┌────┴───────────────────────────┴───────────────┴──────────┐  │
│  │  HomeVM      SettingsVM      PairingVM      StreamingVM  │  │
│  └────┬──────────────┬──────────────┬──────────────┬─────────┘  │
├───────┼──────────────┼──────────────┼──────────────┼────────────┤
│       │         Managers / Services │              │            │
│  ┌────┴─────┐ ┌──────┴──────┐ ┌────┴─────┐ ┌─────┴────────┐   │
│  │Connection│ │  Settings   │ │ Security │ │   Battery    │   │
│  │ Manager  │ │   Manager   │ │ Service  │ │   Manager    │   │
│  └────┬─────┘ └─────────────┘ └──────────┘ └──────────────┘   │
├───────┼────────────────────────────────────────────────────────┤
│       │              Services Layer                             │
│  ┌────┴───────────────────────────────────────────────────┐    │
│  │                   Network Layer                        │    │
│  │  ┌──────────┐ ┌───────────┐ ┌─────────┐ ┌──────────┐  │    │
│  │  │APIServer │ │WebSocket  │ │Bonjour  │ │QRCode    │  │    │
│  │  │(REST)    │ │  Server   │ │Service  │ │Generator │  │    │
│  │  └──────────┘ └───────────┘ └─────────┘ └──────────┘  │    │
│  │  ┌──────────┐ ┌───────────┐ ┌─────────┐               │    │
│  │  │HTTPRouter│ │SpeedMon.  │ │Network  │               │    │
│  │  └──────────┘ └───────────┘ │Service  │               │    │
│  │                              └─────────┘               │    │
│  └────────────────────────────────────────────────────────┘    │
│  ┌────────────────────────────────────────────────────────┐    │
│  │                   Streaming Layer                       │    │
│  │  ┌──────────┐ ┌───────────┐ ┌─────────┐ ┌──────────┐  │    │
│  │  │ Stream   │ │  H.264    │ │  MJPEG  │ │  RTSP    │  │    │
│  │  │ Manager  │ │ Streaming │ │Streaming│ │  Service  │  │    │
│  │  └──────────┘ └───────────┘ └─────────┘ └──────────┘  │    │
│  └────────────────────────────────────────────────────────┘    │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  CameraService  │  FocusManager  │  VideoEncoder       │    │
│  └────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

### Windows Client — MVVM (CommunityToolkit.Mvvm)

```
┌──────────────────────────────────────────┐
│              WPF Views                   │
│         MainWindow.xaml                  │
└──────────────┬───────────────────────────┘
               │
┌──────────────┴───────────────────────────┐
│           MainViewModel                  │
│   (ObservableObject + RelayCommand)      │
└──┬────────────┬──────────────────┬───────┘
   │            │                  │
┌──┴───┐  ┌─────┴──────┐  ┌───────┴──────┐
│Network│  │ VirtualCam │  │   Settings   │
│Client │  │   Driver   │  │   Manager    │
└───────┘  └────────────┘  └──────────────┘
```

### OBS Plugin — Direct Source

```
┌────────────────────────────────────────┐
│           OBS Studio                   │
│  ┌──────────────────────────────────┐  │
│  │     rifatcam_source (C++17)      │  │
│  │  ┌──────────┐  ┌──────────────┐  │  │
│  │  │ Socket   │  │ JPEG Decoder │  │  │
│  │  │ Receiver │→ │ (stb_image)  │  │  │
│  │  └──────────┘  └──────┬───────┘  │  │
│  │                       ↓          │  │
│  │              gs_texture (GPU)    │  │
│  └──────────────────────────────────┘  │
└────────────────────────────────────────┘
```

---

## Project Structure

```
RifatCam_Pro/
├── RifatCamPro/                        # iOS App (Swift 6, SwiftUI)
│   ├── App/
│   │   └── RifatCamProApp.swift        # App entry point
│   ├── Models/
│   │   ├── AppSettings.swift           # App configuration model
│   │   ├── CameraConfiguration.swift   # Camera settings & enums
│   │   ├── NetworkConfiguration.swift  # Network settings & enums
│   │   ├── StreamingState.swift        # Streaming state model
│   │   ├── Configuration/              # Configuration sub-models
│   │   ├── Network/                    # Network data models
│   │   └── Streaming/                  # Streaming data models
│   ├── ViewModels/
│   │   ├── HomeViewModel.swift         # Home screen logic
│   │   ├── SettingsViewModel.swift     # Settings management
│   │   ├── PairingViewModel.swift      # Device pairing logic
│   │   └── StreamingViewModel.swift    # Streaming control
│   ├── Views/
│   │   ├── Components/
│   │   │   ├── GlassCard.swift         # Glassmorphism card
│   │   │   └── StatusIndicator.swift   # Connection status dot
│   │   ├── Home/
│   │   │   ├── HomeView.swift          # Main screen
│   │   │   ├── CameraPreviewView.swift # Live camera preview
│   │   │   ├── StatusBarView.swift     # Connection & stats bar
│   │   │   └── ActionButton.swift      # Control buttons
│   │   ├── Pairing/
│   │   │   ├── PairingView.swift       # QR code display/scanner
│   │   │   └── QRScannerView.swift     # Camera-based QR scanner
│   │   ├── Settings/
│   │   │   ├── SettingsView.swift      # Settings screen
│   │   │   └── ResolutionPicker.swift  # Resolution selector
│   │   └── Streaming/
│   │       ├── StreamingView.swift     # Active stream view
│   │       └── StatsGridView.swift     # Live statistics grid
│   ├── Services/
│   │   ├── Camera/
│   │   │   ├── CameraService.swift     # AVCaptureSession management
│   │   │   ├── FocusManager.swift      # Manual/auto focus control
│   │   │   └── VideoEncoder.swift      # H.264/HEVC encoding
│   │   ├── Network/
│   │   │   ├── APIServer.swift         # REST API server
│   │   │   ├── WebSocketServer.swift   # WebSocket server
│   │   │   ├── BonjourService.swift    # mDNS/Bonjour discovery
│   │   │   ├── HTTPRouter.swift        # HTTP request routing
│   │   │   ├── NetworkService.swift    # Network utilities
│   │   │   ├── QRCodeGenerator.swift   # QR code generation
│   │   │   └── SpeedMonitor.swift      # Bandwidth monitoring
│   │   ├── Security/
│   │   │   └── SecurityService.swift   # Auth, encryption, hashing
│   │   └── Streaming/
│   │       ├── StreamManager.swift     # Stream orchestrator
│   │       ├── H264StreamingService.swift # H.264/HEVC transport
│   │       ├── MJPEGStreamingService.swift # MJPEG multipart stream
│   │       └── RTSPService.swift       # RTSP server
│   ├── Managers/
│   │   ├── ConnectionManager.swift     # Connection lifecycle
│   │   ├── SettingsManager.swift       # UserDefaults persistence
│   │   └── BatteryManager.swift        # Battery & thermal monitor
│   ├── Utilities/
│   │   ├── Constants.swift             # App-wide constants
│   │   └── Extensions.swift            # Swift extensions
│   ├── Resources/
│   │   └── Assets.xcassets/            # Colors, icons, images
│   ├── xcconfig/
│   │   ├── Debug.xcconfig              # Debug build settings
│   │   └── Release.xcconfig            # Release build settings
│   ├── Info.plist                       # iOS configuration
│   └── RifatCamPro.entitlements         # App entitlements
│
├── WindowsClient/                       # Windows Client (C# / .NET 9 / WPF)
│   └── RifatCamPro.Client/
│       ├── App.xaml                     # WPF application entry
│       ├── App.xaml.cs                  # Application startup
│       ├── MainWindow.xaml              # Main window layout
│       ├── MainWindow.xaml.cs           # Window code-behind
│       ├── RifatCamPro.Client.csproj    # Project file
│       ├── Models/
│       │   └── DeviceModel.cs           # Device discovery model
│       ├── ViewModels/
│       │   ├── MainViewModel.cs         # Main UI logic
│       │   ├── ObservableObject.cs      # INotifyPropertyChanged base
│       │   └── RelayCommand.cs          # ICommand implementation
│       ├── Services/
│       │   ├── NetworkClient.cs         # TCP/UDP connection client
│       │   ├── VirtualCamera.cs         # DirectShow virtual camera
│       │   └── SettingsManager.cs       # App settings persistence
│       ├── Behaviors/                   # WPF attached behaviors
│       ├── Converters/                  # Value converters
│       ├── Views/                       # Additional WPF views
│       ├── Themes/
│       │   └── DarkTheme.xaml           # Dark mode resource dictionary
│       └── Assets/                      # Icons, images
│
├── OBSPlugin/                           # OBS Studio Plugin (C++17)
│   ├── CMakeLists.txt                   # Build configuration
│   ├── plugin-main.cpp                  # OBS module registration
│   ├── rifatcam_source.h               # Source class header
│   ├── rifatcam_source.cpp             # Source implementation
│   └── stb_image_impl.cpp              # stb_image compilation unit
│
└── README.md                            # This file
```

---

## Configuration

### iOS App Configuration

Configuration is managed through the in-app settings UI. Key defaults are defined in `Constants.swift`:

| Setting | Default | Range |
|---------|---------|-------|
| Streaming Port | `4747` | `1` - `65535` |
| API Port | `4748` | `1` - `65535` |
| Resolution | 1080p | 480p / 720p / 1080p / 4K |
| Frame Rate | 30 FPS | 15 / 24 / 25 / 30 / 48 / 50 / 60 |
| Codec | H.264 | MJPEG / H.264 / HEVC |
| Bitrate | 4 Mbps | 100 Kbps - 50 Mbps |
| Zoom | 1.0x | 1.0x - 10.0x |
| Exposure ISO | 100 | 25 - 1600 |
| White Balance | 5600K | 2000K - 10000K |
| Connection Timeout | 10s | 1s - 60s |
| Max Connections | 1 | 1 - 5 |
| Auto-Reconnect | Enabled | On / Off |
| Reconnect Attempts | 5 | 1 - 10 |
| Heartbeat Interval | 5s | 1s - 30s |

### Windows Client Configuration

| Setting | Location |
|---------|----------|
| Theme | `Themes/DarkTheme.xaml` |
| Discovery Port | UDP `49383` |
| Buffer Size | 1 MB receive buffer |
| Protocol | MJPEG / H.264 (auto-negotiated) |

### OBS Plugin Configuration

Configurable via the OBS source properties dialog:

| Property | Default | Description |
|----------|---------|-------------|
| IP Address | `192.168.1.1` | iPhone IP address |
| Port | `4747` | Streaming port |
| Password | _(empty)_ | Connection password |
| Target FPS | `30` | Desired frame rate |
| Stream Path | `/video` | MJPEG endpoint |
| Auto Reconnect | `true` | Reconnect on disconnect |
| Reconnect Delay | `5000` ms | Delay between retries |

---

## Troubleshooting

### iPhone App

| Issue | Solution |
|-------|----------|
| Camera permission denied | Go to Settings > Privacy > Camera > RifatCam Pro > Allow |
| Device not discoverable | Ensure both devices are on the same WiFi network; check that the router has mDNS/Bonjour enabled (AP isolation must be off) |
| Stream is choppy | Lower the resolution to 720p or switch to MJPEG codec; ensure a strong WiFi signal |
| High battery drain | Reduce frame rate to 30 FPS; lower resolution; disable torch |
| App crashes on launch | Ensure iOS 17.0+ is installed; reinstall the app |
| Thermal warning | The device is overheating; reduce resolution and frame rate, or pause streaming |

### Windows Client

| Issue | Solution |
|-------|----------|
| Cannot connect | Verify the IP address and port match the iPhone app; check firewall rules |
| Virtual camera not showing | Install OBS Virtual Camera or ensure DirectShow filters are registered |
| Black screen in OBS | Restart OBS; verify the RifatCam source is connected; check the IP/port |
| High latency | Use H.264 codec; ensure both devices are on 5 GHz WiFi or wired Ethernet |
| Connection drops | Enable auto-reconnect; reduce bitrate; check WiFi signal strength |

### OBS Plugin

| Issue | Solution |
|-------|----------|
| Plugin not appearing in OBS | Verify the `.dll` is in `C:\Program Files\obs-plugins\64bit\`; restart OBS |
| "Connection refused" error | Ensure the iPhone app is running and listening; check the port number |
| Stuttering frames | Lower the target FPS in source properties; use a wired connection |
| Build fails | Ensure CMake 3.16+, OBS SDK, and a C++17 compiler are installed |

### Network Tips

- **AP Isolation:** Many routers have "AP Isolation" or "Client Isolation" enabled by default. **Disable this** for device discovery and direct communication to work.
- **Firewall:** Add an exception for the RifatCam Pro ports (`4747` for streaming, `4748` for API) in Windows Firewall.
- **5 GHz WiFi:** Use a 5 GHz WiFi band for the best performance and lowest latency. 2.4 GHz may cause interference and frame drops.
- **VPN:** If a VPN is active on either device, local network discovery will not work. Disconnect the VPN or add a split tunnel exception.

---

## License

This project is licensed under the **MIT License**.

```
MIT License

Copyright (c) 2026 RifatCam

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Contributing

Contributions are welcome. Please follow these guidelines:

### Getting Started

1. Fork the repository.
2. Create a feature branch from `main`:
   ```bash
   git checkout -b feature/my-feature
   ```
3. Make your changes.
4. Test on all affected platforms.
5. Commit with a clear message:
   ```bash
   git commit -m "Add: feature description"
   ```
6. Push and open a Pull Request.

### Code Standards

| Platform | Standard |
|----------|----------|
| **iOS** | Swift 6 strict concurrency, SwiftUI conventions, `@Observable` over `ObservableObject` where possible |
| **Windows** | C# 12, .NET 9, MVVM with CommunityToolkit.Mvvm, nullable enabled |
| **OBS Plugin** | C++17, RAII, `std::atomic` for thread safety, no raw pointers for ownership |

### Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation change
- `refactor:` Code refactor (no feature change)
- `perf:` Performance improvement
- `test:` Adding or updating tests
- `chore:` Build or tooling change

### Pull Request Guidelines

- PRs should target the `main` branch.
- Include a description of what changed and why.
- Attach screenshots or screen recordings for UI changes.
- Ensure no compiler warnings on any target platform.
- Keep PRs focused; one feature or fix per PR.

---

<div align="center">

**Made with care by RifatCam**

[rifatcam.com](https://rifatcam.com) | [support@rifatcam.com](mailto:support@rifatcam.com)

</div>
