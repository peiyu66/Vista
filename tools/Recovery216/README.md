# 216 結案基準核驗

主入口是 `VistaBrowser.xcodeproj` 的 `VistaBrowser` scheme。`Diagnostic` 保持原 216 實驗旗標及日誌；`Release` 不啟用這些播放試驗旗標、不寫 Vista 自製日誌。詳見 [結案範圍](../../docs/development/結案216.md)。

`python3 tools/Recovery216/verify.py` 核對來源及保留產品檔案。一般原生依賴建置／重新連結見 `NativeBuild/README.md`，版本與編譯配置必須另外核對。

本次跳轉、讀取及日誌回歸使用 SwiftPM，傳入 `VISTA_SEEK_CHUNK_1M`、`VISTA_EARLY_SEEK_PLAY`、`VISTA_READ_PHASE216`、`VISTA_NATIVE_PLAYER_EXPERIMENT`、`VISTA_SYSTEM_VIDEO_EXPERIMENT`。濾器為 `ReadPhase216|SeekEarly216|SeekChunk215|MP4SeekDiagnosticsTests|NativePlaybackSessionTests|NativeScrubSubmissionTests`。實際 AVPlayer 情境需提供本機專案生成的 `VISTA_SEEK215_FIXTURE`；未提供時被停用的測試不能算已執行。

adapter 回歸先執行 `python3 tools/ReadPhase216/prepare.py`，再執行 `swift test --package-path .build/read216-harness -Xswiftc -DVISTA_READ_PHASE216`。準備器只補上乾淨 checkout 的驗證目錄建立；沒有產品行為差異。

日誌寫入器可用 `python3 tools/MP4SeekDiagnostics/test_writers.py` 在主機獨立目錄重驗；它不是完整 visionOS App 執行證據。所有實機、上傳或新策略工作須由新任務指示，這些工具不會自動安裝或啟動。
