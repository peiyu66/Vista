# VP9 原生播放

2026-11-07。Build67 的 VP9 MP4 播放、快轉、倍速及摘下再戴上恢復已由使用者實測接受。正式採用下述最小註冊策略；不是 MKV 支援、所有 VP9 檔案或已確認硬體解碼的承諾。來源基底與驗收狀態見 [已驗收基底](已驗收基底.md)。

## 系統註冊策略

`NativePlaybackSession` 在建立 `AVURLAsset` 前，於 MainActor 使用程序內一次性的 `NativeSupplementalVideoDecoders.vp9RegistrationRequested`，呼叫 Apple 公開 API `VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)`。具 macOS 11.0／visionOS 26.2 availability guard；更舊 visionOS 略過註冊，不提高整個 App 的最低版本。

這是對系統既有補充 decoder 的 opt in，不下載、安裝或嵌入第三方 decoder，不轉碼。AVPlayer 仍自行選擇解碼方式，接受系統軟解；無法辨識時保持「系統管理（未知）」，不把 API 被呼叫、硬解查詢值或可讀軌道當成實際解碼器身分。

相對 Build66，產品程式僅新增 20 行（import、helper 與呼叫）。速度能力、背景暫停、手動恢復、renderer／byte-source 恢復、取消及換片清理邏輯不變；SMB vendor、patch、timeout、queue 與來源契約不變。Browser 主入口為 0.1.0 (67)，bundle ID、權限及資料範圍不變。

容器入口仍只允許 mp4／m4v／mov，此次使用者接受的是 **VP9 MP4**。MKV 在來源讀取前拒絕；GPAC、libwebm、FFmpeg 與 MKV/AAC 封裝研究均未接入 App。不能把 MP4 成功推廣為 MOV／M4V 各變體或 MKV 成功。

## 固定來源與測試基線

[NativeVP9Baseline.json](../tools/NativeVP9Baseline.json) 記錄本次基底提交、已接受範圍、OS guard、專案自造 VP9＋AAC 素材及 7 份產品／測試／版號檔的 SHA-256。這些檔案與已安裝驗收 Build67 的來源逐位元相同；不保證重建 App 二進位相同。依賴雜湊 baseline 沿用，沒有更新接受不同 vendor 內容。

[固定精選集合](../tools/NativeVP9TestFilter.txt) 為 49 項／9 suites。除 VP9 播放外，包含 H.264／HEVC 正控制、來源失敗、暫停／seek／停止／重開、速度能力、背景保持暫停，以及 renderer／source 恢復交界。另以全新測試程序先執行 VP9 播放案例，避免先跑註冊探測造成假通過；同一案例不重複計為獨立覆蓋。

VP9 合成素材為 640×360、4 秒、VP9＋AAC，直接沿用專案既有生成檔，未讀取或轉碼私人影片。素材最初由 FFmpeg lavfi `testsrc2=size=640x360:rate=24` 與 `sine=frequency=440:sample_rate=48000` 生成，使用 libvpx-vp9、yuv420p、24 幀 GOP 與 AAC 96k；FFmpeg 不加入 App。原生測試以靜音方式檢查影格與控制，不宣稱自動驗證聲音聽感。恢復交界使用記憶體替身：450 ms 來源恢復超過普通 200 ms stall 界線但在 grace 內，成功後保持暫停，暫停中設 2× 與 seek 不自動播放，明確 resume 才前進。這不是實際 SMB 恢復測試。

命令見 [開發與測試](開發與測試.md#build67-vp9-精選命令)；本輪結果集中在 [Build67 正式整合重驗](已驗收基底.md#build67-正式整合重驗)。

## 驗收與限制

使用者已在 Vision Pro 實測接受播放、快轉、倍速及摘戴恢復。未收集其私人影片、檔名或媒體參數；因此不推定 profile、解析度、HDR、各倍速檔位、長時音畫同步或所有網路條件皆通過。既有部分跳轉等待與 3× 卡頓限制不因本次個別影片成功而全面解除。

本輪正式整合只做本機測試與建置，不再次安裝、啟動或操作實機、不清資料、不連 NAS，也不重新執行受限的 SMB 多請求／Admission 研究。visionOS 26.1 模擬器不具上述 API，不能用其通過或失敗推定 26.2+ 裝置行為。本輪未新增 UI、雙眼光學、4K／8K、其他 VP9 profiles 或長片的驗收。
