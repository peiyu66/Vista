# SMB 讀取生命週期契約

2026-11-03。`SMBReadSession` 已編譯並以可控 transport 驗證，尚未接入 App 播放入口。既有 MP4 播放仍使用原 adapter；MKV 仍拒絕開啟。這份文件是 session 生命週期與版本檢查的正式來源；parser 狀態見 [MKV 與 VP9 評估](MKV與VP9評估.md)。

## 實際依賴的取消能力

查核目前鎖定的 AMSMB2 4.0.3，commit `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`：

- [contents async 包裝與讀取迴圈](https://github.com/amosavian/AMSMB2/blob/1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0/AMSMB2/AMSMB2.swift)：async API 使用 checked continuation，沒有 Swift Task cancellation handler；每次 range read 重新開檔。progress 在一段資料已讀取並寫入 memory stream 後執行，回傳 false 只能停止後續迴圈，不能中止當下的同步讀取。
- [底層等待](https://github.com/amosavian/AMSMB2/blob/1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0/AMSMB2/Context.swift)：poll 等待中，在沒有事件時才檢查既定 timeout；不能把 manager 的 15 秒設定當成所有情況的整體操作期限或即時取消保證。
- [FileHandle](https://github.com/amosavian/AMSMB2/blob/1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0/AMSMB2/FileHandle.swift)：持續開檔、file ID 與 fstat 的型別為內部介面，非現有公開 manager 的穩定 handle API。析構會嘗試關檔並吞掉失敗；回呼返回不能被宣稱為伺服器端 handle 一定已清除。

以上是原始碼查核，不是對真實伺服器執行斷線或取消測試。未呼叫 disconnect、修改分享、讀取憑證或操作已登入畫面。

## 新 session 契約

`SMBReadAdmission.shared` 為預定 MKV 路徑的共用閘門，所有 session 必須使用同一實例；測試可注入隔離閘門。最多一個已取得名額的 session，沒有等待佇列；同 session 最多一個進行中讀取。檢查版本、讀取資料、再次檢查版本依序進行，不新增平行網路請求。

一次請求最多 64 KiB，session 累計資料預算 1 MiB、最多 4,096 次讀取；這是保守的初期驗證界線，不是完整長片資源模型。失敗請求仍耗用預算；錯誤不自動重試。錯誤只回傳固定 enum，不傳出底層 error domain、路徑或帳號。

每次完整讀取有單調計時的期限（預設 15 秒，可在測試縮短）。逾時、呼叫端取消或 close 會使 session 永久關閉、設定共用取消旗標、取消 Swift worker／timer，並對等待者回報一次。AMSMB2 adapter 把旗標接到 progress，且讀取前後再次檢查；沒有宣稱它能中止既有 blocking call。

**名額不在逾時時釋放。**底層 work 尚未返回就保持 draining，後續 session 一律 busy；直到 metadata／read 工作真正返回，丟棄晚到結果並完成清理才釋放。不同 lease token 的過期釋放不能清掉新 session。閒置 session close 或釋放物件也會歸還名額。

如果底層永久不返回，閘門就持續保留，寧可拒絕下一個 session，不靠累積未完成 I/O 維持表面可用。這限制的是本層 transport 工作數量，不保證遠端伺服器在失敗後沒有殘留 handle；錯誤後的真正連線清理仍須整合／實測。這個閘門尚未套用到既有 MP4 adapter，因此不能宣稱目前全部 App I/O 已受此限制。

## 檔案版本：可觀察變動不等於不可變快照

AMSMB2 提供的 `.documentIdentifierKey` 來自 inode 類識別值，不是持續開檔的 SMB FileId。新版本描述包含大小、非零識別碼、內容修改時間與屬性修改時間。缺必要欄位、非一般檔案、異常數值即拒絕。

每次讀取前版本必須與本 session 上次版本相同，讀取後也必須與讀取前相同；大小、識別碼或時間改變即丟棄資料並關閉 session。這可偵測部分替換與修改，但時間精度、伺服器語意、識別碼重用、保留 metadata 或 ABA 變動仍可使不同內容看起來相同。沒有把 stat 比對或首段雜湊誤稱不可變快照。

契約明確分為：

- `requireSnapshot`（預設）：來源須承諾不可變快照。現有 AMSMB2 adapter 固定宣告 observedMetadata，因此在取得名額或任何網路 I/O 前回報 snapshotUnavailable。
- `detectObservableChanges`：明確降低為可觀察 metadata 比對，僅供驗證與未來經確認的降級路徑，沒有提供產品 UI 選項，也未用來開放 MKV。

測試以相同大小、識別碼與時間但不同 byte 的來源，證明第二種模式確實無法偵測這類變動；第一種模式仍拒絕該來源。不可變的合成來源則可在嚴格模式讀取。這是能力分級與安全拒絕，不是已實作網路快照。

## 驗證與剩餘工作

新增 10 個測試涵蓋慢 metadata、慢 read、逾時後 100 次開啟拒絕、舊工作返回後再取得名額、20 個並發 close 與 caller cancellation、斷線／短回覆、讀取中與兩次讀取間換檔、相同 metadata 的內容變動、缺身份欄位、lease 過期釋放、閒置物件釋放、嚴格模式及單次／累計上限。ThreadSanitizer 全數通過；完整核心／媒體 81 測試與 visionOS 建置通過。

沒有真實 SMB 的取消／逾時或遠端 handle 清理驗收，也沒有產品層的 session adapter／cache／parser／播放器整合。MKV 不開放的核心原因是目前公開 transport 無法滿足預設快照契約，以及清理的遠端語意未證實。後續需選擇可驗證的持續來源／快照或明確受限的不可變緩衝策略，不能暗中將嚴格模式切成 metadata 模式。影片硬解政策、第三方授權與實機限制不變。
