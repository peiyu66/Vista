# 持續唯讀 handle 局部修補

這份 incremental patch 套用於既有已接受的 AMSMB2 4.0.3 Swift 來源，已包含既有 readonly-recovery 修補，不是未修補上游的獨立替代品。修改 AMSMB2.swift、FileHandle.swift、Context.swift；沒有修改 libsmb2 C、manifest 或上游測試。

公開入口為 SMB2Manager.openReadOnlyHandle(atPath:)，回傳 Sendable SMB2ReadOnlyHandle，提供 attributes、read(range:) 與 throwing close。開檔要求 FILE_READ_DATA|FILE_READ_EA|FILE_READ_ATTRIBUTES（不額外要求 READ_CONTROL）desired access、READ|WRITE|DELETE 分享、OPEN disposition。只有 CREATE 原始回應 STATUS_NOT_SUPPORTED／STATUS_NOT_IMPLEMENTED 轉為 unsupportedCapability；其餘錯誤不授權 fallback。

開檔及其初始 fstat 同一 counted operation；每 handle 的後續操作放在 serial DispatchQueue，提交時加入 manager operationCount，continuation 回傳後才減計數。每次讀取最多 2 MiB，依 negotiated maxReadSize 切成逐次 positioned reads，正數短讀繼續，零長度停在 EOF。取消只在 C 呼叫前後檢查，不能提前釋放 pointer、立即中斷既有 blocking call 或宣稱遠端 handle 已消失。第一次 attributes 回傳開檔時 cached fstat，其後 fstat 仍使用同一 handle。

原 client 的 fileHandleGeneration 在 disconnect 釋放全部 C handles、或本地 invalidate 前增加。新 API 在原 context lock 下核對 generation 與 fd，再 dereference。close 先解除 Swift ownership，再等實際 C callback；context 已失效時回報 contextUnavailable，僅代表本地放棄。重複 close 不再送 RPC，並保留第一次 close 的成功或錯誤結果；deinit 是 counted best-effort cleanup，不能取代顯式 close。

歷史Build78離線驗證記錄：24 項 boundary tests（包含原有 18 項及新增 6 項）、34 項 source contract checks 通過。本次104 promotion不重跑24項runtime，僅重核靜態來源／patch-chain／hash。測試沒有 NAS、認證、socket SMB 請求、實機或 upstream SMB suite。這些不構成真實伺服器 rename/delete 兼容性、遠端 close 成功、吞吐改善或完整 cancellation 交錯的驗收。

公開入口宣告於 SMB2Manager class body，使用 open func 支援離線 fixture override。CREATE、C handle 建立及初始 fstat 共用原 context lifetime lock；不與 disconnect 釋放 file handles 交錯。

## 對應 Build104 來源 SHA-256

- `Dependencies/AMSMB2/AMSMB2/AMSMB2.swift`: `7edb59a3a92ea3b201b9d1988d545714c07b8a67bf6cae6f10101b2d2176ac17`
- `Dependencies/AMSMB2/AMSMB2/FileHandle.swift`: `1b71b0aee52d5c022be5fe8ef3516a8536c0daf56b4d59a068a00e753a86e0fb`
- `Dependencies/AMSMB2/AMSMB2/Context.swift`: `43949c1e71ed7d2b85e8da9ee368cb040969e9e84cea378310c88adf4cc625a9`
- `DependencyPatches/AMSMB2-4.0.3-persistent-readonly-handle.patch`: `396ac685bb44d698993f9f39283b6d221eeb0a593c90e64a158a20c37b22ae06`


## 套用路徑與修改聲明

此修補於2026-11-08加入持續唯讀handle，修改的三份Swift來源如上；2026-11-09隨已接受104來源整合。保留上游檔頭及原LGPL／各組件授權，不重新授權第三方來源。

須以已套前兩份patch的來源為底。從repo根目錄檢查時使用 `git apply --check --directory=Dependencies/AMSMB2 DependencyPatches/AMSMB2-4.0.3-persistent-readonly-handle.patch`；要重建時可在隔離副本將同命令移除 `--check`。不可在已套此patch的104來源重複套用，也不可從repo根目錄省略directory參數。
