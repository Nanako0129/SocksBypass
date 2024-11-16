# iOS SOCKS5 Server

A fully functional iOS SOCKS5 proxy server application based on the microsocks project.

## Key Features

### 1. Traffic Monitoring
- Real-time upload/download speed display
- Cumulative traffic statistics
- Human-readable data units (B/KB/MB/GB)

### 2. Complete Logging System
- Real-time connection status monitoring
- Colored log display (success/warning/error)
- Auto-scroll to latest logs
- Maximum 1000 lines of log history

### 3. Background Operation
- Supports iOS background mode
- Uses silent audio to keep app running in background
- Does not interfere with other apps' audio playback

## Screenshot
<p align="center">
    <img src="https://github.com/user-attachments/assets/03d37bb4-308c-46f6-b3cb-077372cb7643" alt="screenshot">
</p>


## Installation Guide

1. Clone the project:
```bash
git clone --recursive https://github.com/Nanako0129/iOS-SOCKS-Server.git
```

2. Open Xcode project:
- Open `SOCKS.xcodeproj`
- Select your developer account for signing
- Modify Bundle Identifier to your own

3. Deploy to device:
- Connect your iOS device to computer
- Select your device in Xcode
- Click run button to compile and install

## Usage

1. Launch the application
2. Wait for IP address and port display (default port 9876)
3. Configure SOCKS5 proxy on devices that need proxy:
   - Proxy server: (displayed IP address)
   - Port: (displayed port)
   - No authentication required

## Notes

- This app requires devices to be on the same WiFi network or personal hotspot
- Due to iOS limitations, app must remain active in foreground or background
- Not recommended for App Store distribution due to potential policy violations

## License

This project is licensed under MIT License - see [LICENSE](LICENSE) file

## Acknowledgments

This project is a fork of [nneonneo/socks5-ios](https://github.com/nneonneo/socks5-ios). Special thanks to Robert Xiao (nneonneo) for the original implementation.

Based on [rofl0r/microsocks](https://github.com/rofl0r/microsocks)

---

# iOS SOCKS5 Server

一個功能完整的 iOS SOCKS5 代理伺服器應用程式，基於 microsocks 專案開發。

## 主要功能

### 1. 流量監控
- 即時上傳/下載速度顯示
- 累計流量統計
- 人性化的資料單位顯示(B/KB/MB/GB)

### 2. 完整日誌系統
- 即時連線狀態監控
- 彩色化的日誌顯示(成功/警告/錯誤)
- 自動捲動至最新日誌
- 最多保留1000行日誌記錄

### 3. 背景運作
- 支援 iOS 背景模式
- 使用無聲音訊保持應用程式在背景運作
- 不影響其他應用程式的音訊播放

## 截圖
<p align="center">
    <img src="https://github.com/user-attachments/assets/03d37bb4-308c-46f6-b3cb-077372cb7643" alt="screenshot">
</p>

## 安裝說明

1. Clone 專案:
```bash
git clone --recursive https://github.com/Nanako0129/iOS-SOCKS-Server.git
```

2. 開啟 Xcode 專案:
- 打開 `SOCKS.xcodeproj`
- 選擇你的開發者帳號進行簽署
- 修改 Bundle Identifier 為你自己的識別碼

3. 部署到設備:
- 將 iOS 設備連接到電腦
- 在 Xcode 中選擇你的設備
- 點擊執行按鈕進行編譯和安裝

## 使用方法

1. 啟動應用程式
2. 等待顯示 IP 位址和連接埠(預設為 9876)
3. 在需要使用代理的裝置上設定 SOCKS5 代理:
   - 代理伺服器: (顯示的 IP 位址)
   - 連接埠: (顯示的連接埠)
   - 不需要認證

## 注意事項

- 此應用程式需要在同一個 WiFi 網路或個人熱點下使用
- 由於 iOS 的限制，應用程式必須保持在前景或背景執行
- 不建議透過 App Store 發布，因為可能違反相關政策

## 授權

此專案使用 MIT 授權條款 - 詳見 [LICENSE](LICENSE) 檔案

## 致謝

本專案修改自 [nneonneo/socks5-ios](https://github.com/nneonneo/socks5-ios)，特別感謝 Robert Xiao (nneonneo) 開發的原始版本。

基於 [rofl0r/microsocks](https://github.com/rofl0r/microsocks) 開發
