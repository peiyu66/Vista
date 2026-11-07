# MKV 與 VP9 可行性評估

2026-11-07 現況：Build67 的 VP9 MP4 已實測接受，正式策略見 [VP9 原生播放](VP9原生播放.md)。MKV 仍未接入 App；下方是 2026-11-03 隔離研究歷史，其中的硬解限定、下一步建議與 VP9 尚未成功等敘述不代表現行產品政策或新的採用決定。libwebm 仍只在隔離原型，尚非 App 依賴。

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


## 安全化檢查點（2026-11-03）

原始碼確認兩個獨立界線：`SafeArrayAlloc` 的單次防溢位上限為 2 GiB，不是 Vista 適用的總量預算；`Tracks::ParseTrackEntry` 會先依 CodecPrivate 長度配置，再呼叫 reader。字串、track／cluster／cue 等也有各自配置位置。因此不能以單次 SMB 讀取 64 KiB 就認定 parser 記憶體已有上限。官方 vendor 檔仍原樣保留。

隔離執行檔新增 C++ 配置攔截，單次 256 KiB、同時存活 2 MiB、100,000 次嘗試上限（含追蹤標頭）。H.264／HEVC 正常路徑的追蹤峰值各為 33,770／33,861 bytes，結束歸零。自造 300,000-byte CodecPrivate 在配置階段被拒絕，未送入影片解碼；非法 VINT、未知長度 header、配置預算不足與 128 個固定種子 bit mutation 均完成，沒有程序崩潰、逾時或追蹤配置／reader handle 遺留。AddressSanitizer／UndefinedBehaviorSanitizer 全輪無錯誤回報；這是有限 corpus 的證據，不是完整安全稽核或所有惡意檔案保證。

新快取原型以 64 KiB 區塊、最多 4 區塊 LRU（256 KiB payload）、單來源 1 MiB 累計讀取預算及單一進行中 I/O 工作。700 個同區塊小讀取只呼叫來源一次。跨區塊、驅逐、越界、截斷、耗盡預算、重疊請求、取消與關閉均有測試；取消後清快取、失效 generation，晚到結果不會發布。失敗讀取也耗用預算，防止無界重試。資料是合成非同步來源，不是真 SMB，未加入 App。

### 上一階段未接入播放器的原因（配置障礙已由下輪解除）

1. 配置攔截是測試執行檔的全域 new/new[] hook，不能安全套用到包含 UI、其他套件及多執行緒的 App；C malloc／OS／解碼器配置也不在該預算內。三個 SDK 的 parser archive 仍是官方原始碼，沒有內建此防護。下一步需 parser 專屬配置 context／範圍，而非沿用全域 hook。
2. 同步 C++ parser 到非同步 SMB 尚無已驗證 bridge。快取在取消後保留唯一 active slot，直到後端返回；故能防止無界孤兒 I/O，但無法替不合作的後端保證即時結束。須接入並驗證實際逾時／取消、關閉及來源內容版本契約。
3. 當前 parser 原型仍限制 1 MiB 實體合成檔、單視訊、少量 cluster／sample。這不是長片、音訊或 Cues 跳轉的安全資源模型，不能直接去掉限制以換取大檔支援。

因此本輪完成安全測試基礎與有界快取原型，但產品 MKV 入口保持關閉；沒有新增軟解或修改私人分享。未發現需要更換專案授權的衝突，也沒有權限拒絕，阻礙是尚未完成的工程證據。下一階段應先完成 parser 專屬配置及同步／非同步 bridge，再選最小單視訊範圍接回既有硬解播放器。


## Parser context 與非同步橋接檢查點（2026-11-03）

已消除依賴全域 allocator 攔截的障礙。現在預設編譯路徑將官方固定版本的 44 處 nothrow new 改成 opt-in tag overload，呼叫專屬 context；沒有 context、重入、同 context 並發或取消時拒絕。單次配置請求上限 256 KiB，累計 2 MiB／100,000 次嘗試，釋放不退還額度。使用標準成對 new／delete，沒有替換全域配置函式；不影響無關程式配置。官方原始檔與雜湊保留，衍生源碼由腳本生成並保留 BSD 聲明，不能把衍生版誤稱官方原封版本。

每個 context 只能由一個 parser owner 使用；thread-local 只承載當前 owner 指標，預算本身持續至 session 結束。測試確認缺 context 拒絕、總額耗盡、取消、重入拒絕、不同執行緒獨立預算及同 context 競爭拒絕。H.264／HEVC 合成檔的 parser 累計配置請求各 28,227／28,477 bytes；不是 RSS、存活峰值或整個播放器的記憶體。

三平台衍生 parser＋context 靜態 archive 編譯通過：macOS 232,152 bytes、visionOS simulator 234,248 bytes、visionOS device 233,584 bytes。符號檢查確認沒有標準 new/delete 覆寫；這些體積仍不是 App 安裝增量。C++ bridge 也通過三平台編譯，Swift bridge 通過三平台 Swift 6 typecheck；沒有執行實機。

### 實際同步 parser／非同步來源橋接

同步 parser 在專用 DispatchQueue 上執行，reader 經 C ABI 呼叫 Swift bridge，再由非同步 Task 讀取有界 cache。同步等待使用單調時限，拒絕主執行緒與同 bridge 重疊讀取；context 由呼叫端保留至 parser 返回，不將 callback 的輸出 buffer 交給晚到工作。取消／逾時喚醒等待者並永久封閉 bridge，配置點與最終結果再次檢查取消，晚到回應不發布。

真正 libwebm parser 經此 bridge 讀兩種合成 MKV，各取得 24 樣本，每份檔案只向來源取一次資料。50 ms 逾時、主動取消、同 bridge 另一 parser 競爭、故意忽略取消的來源及晚到清理通過；等待後端返回後，cache 的 active slot 與內容清空。這是可控替身，沒有宣稱 SMB 實測或音畫播放。

無全域 hook 的 parser ASan／UBSan、bridge ASan、128 變異與異常結構測試通過；另開 `--track` 的單執行緒 Probe 驗證 C++ 配置與檔案 handle 歸零。全域追蹤只留作額外測試工具，未進入 archive 或 bridge。尚未完成廣泛 fuzz、TSan 或所有容器結構的安全審核。

### 本輪仍保守不開放 App MKV

現有 `SMBMediaReader.close()` 只設 closed 狀態，range transport 呼叫 AMSMB2 contents；雖 manager 設 15 秒 timeout，尚未證實能在逾時／取消後中止全部底層工作。新 bridge 可以及時停止 parser，但不能替不合作來源保證立即釋放。仍需跨播放 session 的共享 admission／cleanup，確保舊 I/O 真正結束前不建立無界的新 session。

此外，現有來源沒有固定檔案快照／版本契約，不能保證不同區塊在檔案被替換時屬於同一版本。原型也仍限 1 MiB 合成檔、24 個樣本，尚未將 bridge 樣本接至既有播放器的音訊、跳轉及生命週期。基於這些具體缺口，產品 MKV 入口保持關閉；不是因為配置 context 不可行，也不是授權或權限被拒絕。下一步先補實際 transport 的生命週期、跨 session 資源上限與來源一致性，再驗證最小單視訊硬解路徑。


## SMB 契約接續（2026-11-03）

已新增共享 admission、draining、整體期限及讀取前後版本比對的 `SMBReadSession`，並實際接上 AMSMB2 的可用 progress 取消旗標；尚未掛入 App 播放流程。10 個契約測試、ThreadSanitizer、全套 81 測試與 visionOS 建置通過。真正 blocking I/O 不能靠 Task.cancel 即時中止，故逾時後保留名額直到後端返回。

版本檢查分成嚴格不可變快照與明確的 metadata 偵測。現有 adapter 不具快照承諾，預設在網路 I/O 前拒絕；相同 metadata 的內容變動已以測試證明不能偵測。MKV 仍不開放，不能為了接線改用較弱模式而不說明。契約、依賴來源及下一步界線統一見 [SMB 讀取生命週期](SMB讀取生命週期.md)。
