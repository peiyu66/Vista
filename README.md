# Vista

Vista 是面向 Apple Vision Pro 的 visionOS VR 影片播放器開源原型，尚無 App Store 版本。

目前提供 SMB 與經使用者授權的本機資料夾瀏覽、影片播放／暫停／跳轉／前後檔、手動 180°／360°／置中等距魚眼投影、單眼／左右／上下排列，以及逐片格式保存。主要播放使用 Apple AVPlayer，解碼方式由系統管理；無法辨識時顯示未知。

開發入口為 VistaBrowser.xcodeproj 的 VistaBrowser scheme。現行來源、驗收範圍及已知問題見 [已驗收基底](docs/已驗收基底.md)，原有架構與測試歷史見 [開發與測試](docs/開發與測試.md)。摘戴後退出 App 與部分跳轉等待仍待改善，未宣稱完整 VP9／MKV 或 HDR 相容性。

採用 [MIT License](LICENSE)；第三方依賴依各自授權，見 [授權與貢獻](docs/授權與貢獻.md)。
