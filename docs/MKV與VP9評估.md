# MKV 與 VP9 可行性評估

2026-11-03。候選方案與實驗結果，不是已採用依賴或已發布功能。現行能力矩陣見 [開發與測試](開發與測試.md#容器與編碼矩陣2026-11-03)。

## 公開框架與實測

AVFoundation 提供容器解析；Core Media 描述壓縮軌道與樣本；VideoToolbox 負責硬解。三者不能互相代替：認得 VP9 codec 不代表能讀 MKV，能讀 MKV 也不代表裝置能硬解 VP9。

以自造灰階 VP9 Profile 0、8-bit 4:2:0、64×64、12 fps、2 秒無音軌 MP4，經 Vista 正式範圍來源／播放器測試：本次 Mac 可辨識 VP9 軌道，但 `VTIsHardwareDecodeSupported(VP9)` 為 false，require-hardware 路徑回報 hardwareUnavailable，沒有輸出影格。這是安全停止的證據，不是 VP9 播放通過，也不能推論其他 Mac 或 Vision Pro 均不支援。

同一份壓縮資料只換成 MKV 封裝，AVURLAsset 原生視訊軌道探測回傳 `AVFoundationErrorDomain -11828`。Vista 產品仍在讀取來源前拒絕 MKV；原生探測是獨立測試，不是加入產品後門。

[VTIsHardwareDecodeSupported](https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:)) 在本機 visionOS SDK 標示 visionOS 1.0 起可用，但 true 仍不保證當下有硬解資源。最終仍須 require-hardware 建立 session、檢查實際使用硬解屬性，再以有效壓縮樣本確認影格。不得以軟解檢查「影片能播放」取代此證據。本輪未操作實機，模擬器也不能代表裝置硬體。

macOS 的 [MediaExtension](https://developer.apple.com/documentation/mediaextension) 是另一種格式擴充機制；[Apple 列出的能力](https://developer.apple.com/help/account/reference/supported-capabilities-macos/) 屬 macOS。沒有把它當成 visionOS 通用 MKV 解決方案，也不為這個原型新增相關 entitlement。

## 解封裝候選比較

以下體積／效能是工程推估，尚未編譯量測，不能當成 MB 或吞吐量承諾。

| 路線 | 範圍與成本 | 授權與分發 |
| --- | --- | --- |
| Apple 原生 | 不增加第三方二進位；本次 MKV 樣本不可解析 | 使用公開 API；仍需正常 App Review |
| libwebm 的 mkvparser 子集 | 純容器 C++，有位置／長度讀取介面、Block／lacing／Cues 結構；需 Swift/C++ 邊界、SMB 有界快取、取消及樣本時間轉換。預期比完整多媒體套件精簡，但尚無 visionOS build／效能數據 | 官方 BSD-3-Clause 與額外專利授權文字；可保留 Vista 自有程式 MIT，必須隨分發保留第三方聲明，不能把它改標 MIT |
| libmatroska＋libebml | Matroska 專用 C++ 元件，兩個依賴；需相同的 Core Media／SMB 整合 | LGPL-2.1 系列，須針對實際版本、連結方式、原始碼與重新連結權利完成分發設計；不直接宣稱與 App Store 不相容或已合規 |
| FFmpeg libavformat 最小建置 | 容器處理成熟，但組態／依賴稽核較多；必須排除影片軟解及不需要的協定，不能直接嵌入本機完整套件 | 預設 LGPL，啟用 GPL 元件會改變適用條件；本機工具含 GPL 組態，不作為 App 可分發二進位 |
| 自製有限 EBML parser | 可限制功能與維持 MIT；需自行承擔未知長度、巢狀上限、lacing、索引、損壞輸入等長期安全測試 | 無新增第三方程式授權，但工程維護負擔最大，不能用小型 header reader 假稱完整 MKV |

官方依據：[libwebm 原始碼與建置](https://github.com/webmproject/libwebm)、[BSD 授權](https://raw.githubusercontent.com/webmproject/libwebm/main/LICENSE.TXT)、[專利文字](https://raw.githubusercontent.com/webmproject/libwebm/main/PATENTS.TXT)、[libmatroska](https://github.com/Matroska-Org/libmatroska)、[libebml](https://github.com/Matroska-Org/libebml)、[FFmpeg 授權與組態](https://ffmpeg.org/legal.html)。App Store 分發另外須依 [Apple 審查規範](https://developer.apple.com/app-store/review/guidelines/) 核對公開 API、程式完整打包與權利；開源授權合適不等於審查保證。

## 建議的下一個可驗證階段

建議選 libwebm 官方 mkvparser 子集作隔離原型，先固定版本／雜湊並保留 LICENSE、PATENTS、AUTHORS，再量測 macOS／visionOS 編譯、增加的二進位體積及解析記憶體。這是待確認的依賴選擇，本輪尚未下載建置或加入 App。

第一步應只做單視訊 H.264／HEVC 合成 MKV 的有界解封裝與強制硬解；不讓 VP9 硬解可用性阻塞整個 MKV 工作。依 [Matroska codec mapping](https://www.matroska.org/technical/codec_specs.html) 處理 CodecPrivate、時間戳、關鍵影格及 sample description，不能只搬移 bytes 就假設等同 MP4。後續才接音訊、Cues 定位、快速取消、多 GOP、損壞輸入與真 SMB；未支援加密、壓縮 header、複雜 lacing 等情形須明確拒絕或另作驗收。

libwebm 的同步位置讀取需與非同步 SMB 協調：避免在主執行緒等待，限制單次讀取、索引數量、深度及總快取，舊工作取消後不能送樣本至新播放器。直接餵 VideoToolbox 可避免完整暫存／轉碼，但需重構目前依賴 AVAssetReader 的音訊與跳轉邊界。VP9 仍只在實際裝置證實硬解後開放；不能以引入 demux 為由放寬政策。

## 重現方式

`tools/GenerateSyntheticVP9.sh` 只使用已安裝的 FFmpeg，從 lavfi 自造像素編碼，再以 `-c copy` 封裝 MKV，不讀取外部影片、不解碼影片、不安裝工具。FFmpeg／libvpx 沒有加入 App 或專案連結依賴，僅提交本專案自造素材；產生器拒絕覆寫。重建時 MKV 識別碼可能不同，不能要求位元完全相同。

執行 `swift test --no-parallel --filter VP9CapabilityTests`。診斷測試允許平台回報不可用，需查看 `VP9_ACTUAL_HARDWARE_VERIFIED` 或不可用標記，不能只看測試綠燈。素材雜湊與本輪完整結果見 [驗收](驗收.md)。
