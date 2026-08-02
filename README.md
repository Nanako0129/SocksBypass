# iOS SOCKS5 Server

A SOCKS5 proxy server that runs on your iPhone, so other devices on the same
network can route traffic through it.

> ### ⚠️ There is no password
>
> The proxy accepts **NO AUTH** connections. Anyone who can reach your phone's
> address and port can use it as an open relay — including anything else on the
> café Wi-Fi, the hotel LAN, or a VPN that puts your devices on one flat
> network. Run it only on a network you control, and stop the app when you are
> done. The app shows the same warning on screen and it is not dismissible.

## Features

- **SOCKS5**: NO AUTH, `CONNECT`, and `UDP ASSOCIATE`
- **Addressing**: IPv4, IPv6, and domain names (ATYP `0x01` / `0x04` / `0x03`)
- **Traffic monitoring**: live upload/download rate, cumulative totals, active
  TCP/UDP session counts, and a recent-activity log
- Written in Swift on Network.framework; no C proxy is linked into the app

## Requirements

- iOS 17.0 or later
- Xcode with a signing account (a free Apple ID works)

## Screenshot

<p align="center">
    <img src="https://github.com/user-attachments/assets/03d37bb4-308c-46f6-b3cb-077372cb7643" alt="screenshot">
</p>

## Installation

1. Clone the project:
```bash
git clone https://github.com/Nanako0129/SocksBypass.git
```

2. Open the Xcode project:
- Open `SocksBypass.xcodeproj`
- Select your developer account for signing
- Change the Bundle Identifier to your own

3. Deploy to a device:
- Connect your iOS device
- Select it in Xcode
- Run

## Usage

1. Launch the app
2. Wait for the IP address and port to appear (default port 9876)
3. On the device that should use the proxy, configure SOCKS5:
   - Proxy server: the displayed IP address
   - Port: the displayed port
   - No authentication

For USB instead of Wi-Fi, use [danielpaulus/go-ios](https://github.com/danielpaulus/go-ios)
forward mode: `ios forward 1080 9876`, then point the client at `127.0.0.1`.

## Known limitation

If a client half-closes its write side (`shutdown(SHUT_WR)`) while a large
response is still arriving, the tail of that response can be lost. The cause is
Network.framework: once a half-closed connection finishes closing, bytes still
sitting in the receive buffer are discarded, and the framework exposes no option
to drain them. BSD sockets do not behave this way, which has been confirmed on
device.

The relay never reports this as success — a truncated stream is aborted with a
reset rather than a clean end-of-stream, so the client sees a connection error
instead of a short file that looks complete. Ordinary HTTP clients and browsers
do not half-close mid-response and are not affected.

## Notes

- The client and the phone must be able to reach each other: same Wi-Fi network,
  personal hotspot, or USB
- Not suitable for App Store distribution

## Development

- `Bench/socks_bench.py` is the protocol and throughput harness. `--mode
  self-test` runs everything against a local proxy with no device involved.
- The `Benchmark` build configuration links a vendored
  [hev-socks5-server](https://github.com/heiher/hev-socks5-server) build, used
  only to compare engines. The shipping app does not include it. Licences for
  the vendored code are in `ThirdPartyNotices/`.

## License

This project is licensed under MIT License - see [LICENSE](LICENSE) file

## Acknowledgments

This project is a fork of [nneonneo/socks5-ios](https://github.com/nneonneo/socks5-ios).
Special thanks to Robert Xiao (nneonneo) for the original implementation, which
was based on [rofl0r/microsocks](https://github.com/rofl0r/microsocks). The
SOCKS5 core has since been rewritten in Swift and no longer contains microsocks.

---

# iOS SOCKS5 Server

一個跑在 iPhone 上的 SOCKS5 代理伺服器，讓同一個網路裡的其他裝置可以透過它連線。

> ### ⚠️ 沒有密碼
>
> 這個代理接受 **NO AUTH** 連線。任何能連到你手機位址與連接埠的人都能把它當
> 開放中繼使用——包括咖啡廳 Wi-Fi、旅館區網，或是把你的裝置放進同一個扁平網路
> 的 VPN 上的任何東西。只在你自己掌控的網路上使用，用完就把 app 關掉。app 內
> 也有同樣的警告，且無法關閉。

## 功能

- **SOCKS5**：NO AUTH、`CONNECT`、`UDP ASSOCIATE`
- **位址型別**：IPv4、IPv6、網域名稱（ATYP `0x01` / `0x04` / `0x03`）
- **流量監控**：即時上傳/下載速率、累計流量、TCP/UDP 連線數、近期活動記錄
- 以 Swift 搭配 Network.framework 實作，app 內不再連結任何 C 代理程式

## 需求

- iOS 17.0 以上
- Xcode 與一個簽署帳號（免費 Apple ID 即可）

## 截圖

<p align="center">
    <img src="https://github.com/user-attachments/assets/03d37bb4-308c-46f6-b3cb-077372cb7643" alt="screenshot">
</p>

## 安裝說明

1. Clone 專案：
```bash
git clone https://github.com/Nanako0129/SocksBypass.git
```

2. 開啟 Xcode 專案：
- 打開 `SocksBypass.xcodeproj`
- 選擇你的開發者帳號進行簽署
- 修改 Bundle Identifier 為你自己的識別碼

3. 部署到裝置：
- 將 iOS 裝置連接到電腦
- 在 Xcode 中選擇你的裝置
- 執行

## 使用方法

1. 啟動應用程式
2. 等待顯示 IP 位址和連接埠（預設為 9876）
3. 在需要使用代理的裝置上設定 SOCKS5：
   - 代理伺服器：顯示的 IP 位址
   - 連接埠：顯示的連接埠
   - 不需要認證

如果想用 USB 而非 Wi-Fi，可以使用 [danielpaulus/go-ios](https://github.com/danielpaulus/go-ios)
的轉發模式：`ios forward 1080 9876`，用戶端指向 `127.0.0.1`。

## 已知限制

如果用戶端在大型回應還在傳輸時關閉了自己的寫入端（`shutdown(SHUT_WR)`），該回應
的尾端可能遺失。原因在 Network.framework：半關閉的連線一旦走完關閉流程，還留在
接收緩衝區裡的資料就會被丟棄，而框架沒有提供排空的選項。BSD socket 沒有這個行為，
這一點已在裝置上驗證。

relay 不會把這種情況當成成功——被截斷的串流會以 reset 中止，而不是送出乾淨的
結束訊號，所以用戶端看到的是連線錯誤，而不是一個看起來完整的短檔案。一般的 HTTP
用戶端與瀏覽器不會在回應中途半關閉，不受影響。

## 注意事項

- 用戶端與手機必須能互相連通：同一個 Wi-Fi 網路、個人熱點，或 USB
- 不適合透過 App Store 發布

## 開發

- `Bench/socks_bench.py` 是協定與吞吐量測試工具。`--mode self-test` 完全在本機
  對一個本地代理執行，不需要裝置。
- `Benchmark` 建置組態會連結一份 vendored 的
  [hev-socks5-server](https://github.com/heiher/hev-socks5-server)，僅用於引擎
  比較，正式 app 不包含它。vendored 程式碼的授權條款放在 `ThirdPartyNotices/`。

## 授權

此專案使用 MIT 授權條款 - 詳見 [LICENSE](LICENSE) 檔案

## 致謝

本專案修改自 [nneonneo/socks5-ios](https://github.com/nneonneo/socks5-ios)，特別
感謝 Robert Xiao (nneonneo) 開發的原始版本，該版本基於
[rofl0r/microsocks](https://github.com/rofl0r/microsocks)。SOCKS5 核心其後已改以
Swift 重寫，不再包含 microsocks。
