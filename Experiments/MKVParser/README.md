# MKV 隔離原型

此目錄只供受信任的自造素材實驗，不是 App 的 MKV 入口，也不接受私人或不可信影片。未加入根目錄 Package.swift 或 Xcode target。

執行 `python3 Experiments/MKVParser/run.py`，需要既有 Xcode、Python 3、FFmpeg；工具不自動下載或安裝依賴。它會驗證 vendor 雜湊，在系統暫存目錄建立獨立輸出，將專案兩份自造 MP4 以 stream copy 封裝成 MKV，再解析及強制硬解。只輸出固定 codec、數量與限制結果，不記錄來源路徑或帳密。暫存輸出僅含自造素材及編譯檔。

- `Probe.cpp`：64 KiB 單次讀取、1 MiB 累計讀取、50,000 次呼叫上限；只接受 1 MiB 以下實體測試檔、單視訊 H.264／HEVC、64×64、24 個無 lacing 樣本、最多 8 clusters。這些限制是實驗條件，不是完整 MKV 支援規格。
- `HardwareProbe.swift`：從 CodecPrivate 建立 avcC／hvcC 格式，直接送壓縮樣本至 require-hardware VideoToolbox session，每批核對實際硬解屬性；沒有影片軟解、轉碼或畫面呈現。硬解不可用會輸出獨立標記，不能以程序退出成功當成已播放。
- `run.py`：正常解析、重讀相同範圍、4 GiB 虛擬 Void 跳讀、負位移／超界／過大讀取、立即／中途取消、低預算及截斷 header；並編譯 macOS、visionOS simulator／device SDK 的靜態 parser archive，以及 typecheck 硬解探針。device SDK 編譯不操作實機。

Reader 使用同步 pread 替身，並非 SMB；取消是確定性注入，不是跨執行緒網路競態測試。未量測正式播放、音畫同步、Cues 跳轉或峰值記憶體。libwebm 內部配置可發生在 reader callback 之前，外層讀取上限不能保證完整解析記憶體上限。現已加入獨立程序專用的配置攔截與變異測試，但此攔截不能連結 App，因此仍不能直接處理不可信網路檔案。

版本、授權、體積與後續整合界線統一見 [MKV 與 VP9 評估](../../docs/MKV與VP9評估.md)。自有探針依專案 MIT；vendor 檔案維持各自原始授權。


## 安全與快取實驗

`python3 Experiments/MKVParser/run.py --sanitize` 加上 AddressSanitizer／UndefinedBehaviorSanitizer；測試固定種子的 128 個 bit mutation、超大 CodecPrivate、非法 VINT、未知長度 header、低配置預算與既有取消／截斷案例。讀取器建構失敗也會關閉已開啟的檔案，正常與失敗路徑均核對檔案 handle 與追蹤的 C++ 配置歸零。

`AllocationBudget.cpp` 僅連結單執行緒實驗執行檔：C++ new/new[] 含追蹤標頭的單次上限 256 KiB、同時存活上限 2 MiB、嘗試次數上限 100,000。它不攔截 C malloc／系統／解碼器記憶體，不代表 RSS 上限。不得連結 App，也不加入三個平台的 parser archive；需改為 parser 專屬配置 context 並重新驗證後才可用於產品。

`BoundedRangeCache.swift` 是獨立的非同步來源原型：64 KiB 區塊、4 區塊 LRU、1 MiB 累計讀取預算、單次請求不超過 64 KiB、最多一個進行中讀取。多餘併發直接 busy；沒有無界排隊。取消清空快取與失效 generation，忽略晚到資料；保留 active slot 到後端實際完成，避免留下無界孤兒 I/O。後端不理會取消時不能保證立即完成，因此真 SMB adapter 必須有可驗證逾時／中止契約，不能以此原型宣稱已解決網路取消。

`CacheTests.swift` 在 Swift 6 嚴格並行模式驗證 700 個小讀取合併、跨區塊、LRU 驅逐、位移／大小界線、預算、截斷、busy、直接取消／呼叫端取消、晚到結果、關閉後拒絕。快取限制是資料 payload 上限，不是整個 Swift runtime 的記憶體保證；來源必須遵守請求範圍並限制其回傳配置。尚未建立同步 C++ reader 與非同步來源的產品 bridge。
