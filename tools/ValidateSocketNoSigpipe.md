# SO_NOSIGPIPE 本機驗證

用途：只驗證 macOS socket 選項機制與候選實際 `socket.c` 的客戶端 socket 初始化路徑。不是 SMB 整合測試，也不判定 Vision Pro 原退出原因或聲稱已修復。

## 重跑

從任意目錄執行 `python3 tools/ValidateSocketNoSigpipe.py`（在儲存庫根目錄），或使用腳本絕對路徑。

需要 macOS 與既有 Apple clang。不下載或安裝依賴、不建置 Swift／Xcode、不接 NAS、外網或 SMB、不操作實機、不修改產品／依賴。輸出預設位於本儲存庫忽略追蹤的 `.build/socket-nosigpipe/`；可用 `--output /path/to/results` 指定獨立結果目錄。

## 22 項覆蓋

- 15 項正式程式路徑：直接 include 完整實際 `Dependencies/AMSMB2/Dependencies/libsmb2/lib/socket.c`，只把 socket、setsockopt、connect、close、fcntl、getprotobyname 與錯誤回報替換成本機記錄替身；用 dead_strip 排除未用的 SMB 函式，沒有另抄演算法。IPv4／IPv6 各驗證立即成功、EINPROGRESS、選項 EPERM／ENOPROTOOPT、socket EMFILE、connect ECONNREFUSED；另驗證兩個新 fd 都再次設定選項及拒絕不支援的 family。
- 7 項 OS 機制／隔離：未保護且對端關閉時單次 writev 使子程序收到 SIGPIPE；保護組回 EPIPE 且存活；保護前後正常傳輸相同10 bytes；對端與下一個新 socket 不會繼承保護；父程序 signal 狀態不變。
- 每個子程序獨立將 SIGPIPE 設為預設並解除封鎖，有5秒保護計時；只使用 AF_UNIX socketpair，每次最多一對，按順序執行，不改父程序或 app 的全域 signal。
- 編譯後先用 nm 檢查執行檔沒有真實 socket、connect、getaddrinfo、getprotobyname、send／sendto／sendmsg imports，才允許執行機制測試。socketpair 僅供本機實測。

事件字母：S=socket、G=SO_NOSIGPIPE、F=fcntl、T=TCP_NODELAY、C=替身 connect、E=錯誤、X=替身 close。成功順序必須為 SGFFTC；選項失敗必須為 SGEX，且 fd_out 不變、沒有 connect 或後續設定。

錯誤替身刻意把 errno 改為 EDOM，close 替身改為 EBADF 並回失敗。候選仍須回傳最初選項錯誤的負值並記錄原錯誤，證明清理不蓋掉要傳回的錯誤。這不要求函式離開時全域 errno 仍相同。

## 產物與限制

result.json 包含22項逐項結果、來源／驗證器 SHA-256、工具與平台、命令及限制。results.tap 為原始結果，compile.log 保存編譯警告，commands.txt 保存完整命令，undefined-symbols.txt 保存連結符號檢查。

AF_UNIX 成功不能替代 TCP、SMB、visionOS 或實機測試。正式函式測試在 syscall 邊界使用替身，沒有證明真正 IPv4／IPv6 網路連線成功；也不涵蓋重試、斷線恢復、背景生命周期、NAS 行為或併發。上游未用函式可產生編譯警告，須照實保存，不修改依賴以消除警告。
