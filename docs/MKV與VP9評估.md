# MKV 與 VP9 可行性評估

2026-11-03。候選方案與實驗結果；libwebm 已限於隔離原型採用，尚非 App 依賴或已發布功能。現行能力矩陣見 [開發與測試](開發與測試.md#容器與編碼矩陣2026-11-03)。

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
| libwebm 的 mkvparser 子集 | 純容器 C++，有位置／長度讀取介面、Block／lacing／Cues 結構；需 Swift/C++ 邊界、SMB 有界快取、取消及樣本時間轉換。已完成三個 Apple SDK 的隔離靜態編譯，體積見下方；沒有網路／播放效能數據 | 官方 BSD-3-Clause 與額外專利授權文字；可保留 Vista 自有程式 MIT，必須隨分發保留第三方聲明，不能把它改標 MIT |
| libmatroska＋libebml | Matroska 專用 C++ 元件，兩個依賴；需相同的 Core Media／SMB 整合 | LGPL-2.1 系列，須針對實際版本、連結方式、原始碼與重新連結權利完成分發設計；不直接宣稱與 App Store 不相容或已合規 |
| FFmpeg libavformat 最小建置 | 容器處理成熟，但組態／依賴稽核較多；必須排除影片軟解及不需要的協定，不能直接嵌入本機完整套件 | 預設 LGPL，啟用 GPL 元件會改變適用條件；本機工具含 GPL 組態，不作為 App 可分發二進位 |
| 自製有限 EBML parser | 可限制功能與維持 MIT；需自行承擔未知長度、巢狀上限、lacing、索引、損壞輸入等長期安全測試 | 無新增第三方程式授權，但工程維護負擔最大，不能用小型 header reader 假稱完整 MKV |

官方依據：[libwebm 原始碼與建置](https://github.com/webmproject/libwebm)、[BSD 授權](https://raw.githubusercontent.com/webmproject/libwebm/main/LICENSE.TXT)、[專利文字](https://raw.githubusercontent.com/webmproject/libwebm/main/PATENTS.TXT)、[libmatroska](https://github.com/Matroska-Org/libmatroska)、[libebml](https://github.com/Matroska-Org/libebml)、[FFmpeg 授權與組態](https://ffmpeg.org/legal.html)。App Store 分發另外須依 [Apple 審查規範](https://developer.apple.com/app-store/review/guidelines/) 核對公開 API、程式完整打包與權利；開源授權合適不等於審查保證。

## 建議的下一個可驗證階段

已依後續授權採用 libwebm 官方 mkvparser 子集作隔離原型，固定版本／雜湊並保留 LICENSE、PATENTS、AUTHORS。尚未加入 App；正式整合需先處理下述安全與架構缺口。

第一步應只做單視訊 H.264／HEVC 合成 MKV 的有界解封裝與強制硬解；不讓 VP9 硬解可用性阻塞整個 MKV 工作。依 [Matroska codec mapping](https://www.matroska.org/technical/codec_specs.html) 處理 CodecPrivate、時間戳、關鍵影格及 sample description，不能只搬移 bytes 就假設等同 MP4。後續才接音訊、Cues 定位、快速取消、多 GOP、損壞輸入與真 SMB；未支援加密、壓縮 header、複雜 lacing 等情形須明確拒絕或另作驗收。

libwebm 的同步位置讀取需與非同步 SMB 協調：避免在主執行緒等待，限制單次讀取、索引數量、深度及總快取，舊工作取消後不能送樣本至新播放器。直接餵 VideoToolbox 可避免完整暫存／轉碼，但需重構目前依賴 AVAssetReader 的音訊與跳轉邊界。VP9 仍只在實際裝置證實硬解後開放；不能以引入 demux 為由放寬政策。

## 重現方式

`tools/GenerateSyntheticVP9.sh` 只使用已安裝的 FFmpeg，從 lavfi 自造像素編碼，再以 `-c copy` 封裝 MKV，不讀取外部影片、不解碼影片、不安裝工具。FFmpeg／libvpx 沒有加入 App 或專案連結依賴，僅提交本專案自造素材；產生器拒絕覆寫。重建時 MKV 識別碼可能不同，不能要求位元完全相同。

執行 `swift test --no-parallel --filter VP9CapabilityTests`。診斷測試允許平台回報不可用，需查看 `VP9_ACTUAL_HARDWARE_VERIFIED` 或不可用標記，不能只看測試綠燈。素材雜湊與本輪完整結果見 [驗收](驗收.md)。


## libwebm 隔離原型結果（2026-11-03）

來源固定為官方 `libwebm-1.0.0.32`，commit `f2a982d748b80586ae53b89a2e6ebbc305848b8c`。只採原樣 mkvparser.cc、mkvparser.h、common/webmids.h，合計 230,595 bytes；原始 BSD-3-Clause、PATENTS 與 AUTHORS 一併保存，逐檔 SHA-256 可核對。來源與聲明見 [原型 vendor](../Experiments/MKVParser/vendor/libwebm/UPSTREAM.md)。沒有改變 Vista 自有 MIT，也沒有引入解碼器、套件管理器安裝或 App 依賴。

以 C++11、`-O2` 編譯單一 parser，macOS arm64 靜態 archive 227,728 bytes、visionOS simulator arm64 229,816 bytes、visionOS device arm64 229,168 bytes；硬解 Swift 探針也通過三個 SDK typecheck。數字是本次原型 archive，包含物件／符號成本，不能視為 App 安裝體積增量。Mac parser 可執行檔僅連結系統 libc++／libSystem。這證明當前工具鏈可編譯，不是上游正式保證所有 Apple 平台，也不是實機執行成功。

兩份專案自造 MP4 只重新封裝為 MKV，分別解析出 H.264／HEVC 單軌、CodecPrivate 與 24 個壓縮樣本。Mac 以 avcC／hvcC 建立 Core Media format，require-hardware session 及每批實際硬解屬性均通過，兩者各解出 24 幀。原型沒有顯示、排程或聲音，不能等同完整 MKV 播放器。

H.264 解析與重讀共 687 次、2,731 bytes、最大單次 127 bytes；HEVC 699 次、2,180 bytes、最大 99 bytes。虛擬插入 4 GiB Void 後，仍取得完全相同的壓縮樣本與 CodecPrivate，讀取量各只增加 11 bytes；沒有建立 4 GiB 檔案。證明位置介面可跳讀大位移，不能當成真 SMB 或長片索引效能。

### SMB 與安全缺口

同步 `IMkvReader` 的位置／長度介面能對應隨機讀取，但不能把每個小呼叫直接變成網路請求：本次不到 3 KB 就有近 700 次呼叫。正式整合需要工作執行緒、有界區塊快取／合併、非同步取消與來源版本一致性；不得阻塞主執行緒或一次下載整片。

原型 reader 限單次 64 KiB、累計 1 MiB、50,000 次呼叫，並測試立即／中途取消、超界與截斷。但 libwebm 內部可在讀取 callback 前配置記憶體；外層讀取預算不等於完整記憶體防護。尚未做惡意元素尺寸、內部配置上限、模糊測試、完整網路競態與資源耗盡驗證。因此原型限受信任合成檔，不能直接作為 SMB 任意檔案入口。硬解 session 與顯示排序也須接回既有播放器，而不是並存另一套未受控播放管線。

### 分發與後續範圍

BSD 條件允許源碼及二進位重散布，需保留著作權、條件與免責，不得借作者名背書。靜態與動態連結皆需保留聲明；此元件本身不要求 LGPL 式重新連結安排。原型只驗證靜態 archive，沒有建置／簽署動態 framework 或 XCFramework。若加入 App，需納入相符的來源清單與 bundled notices、版本更新／安全檢查及 App Store 整體審查；目前的開發目錄聲明不等於已完成 App 分發合規，PATENTS 也不代表所有 H.264／HEVC 專利均被涵蓋。

下一合理工作是限制資源的 demux adapter 與可測取消／快取，再接單視訊 MKV 硬解；音訊、Cues 定位、lacing、字幕、加密及未知 CodecState 不可順帶宣稱完成。沒有因原型可行而放寬硬解政策，VP9 本次 Mac 仍不可硬解。沒有新增需要使用者選擇的授權衝突；正式導入之前仍需逐項完成安全與分發工程。
