# SMB 目錄一次恢復

2026-11-07。Build64 的切目錄退出修正已由使用者實測接受並結案。本文件是正式採用的 SMB 防護、目錄恢復及依賴修改範圍；驗證與來源組合界線見 [已驗收基底](已驗收基底.md)。這不是所有退出的根因結論。Build66 已接受的播放專用恢復另見 [播放中斷恢復](播放中斷恢復.md)；本頁保留既有目錄 runner 與依賴策略，並說明兩者的補頁銜接。

## 使用者行為與一次預算

目前目錄的唯讀清單遇到失效 session、已知傳輸錯誤或未分類的 session 讀取錯誤時，保留載入狀態，等舊工作真正結束後，以原來源與既有登入資料建立一次新連線，再列舉一次。恢復失敗才顯示必要錯誤；明確權限、認證、不存在、取消及持續性參數錯誤不以反覆登入掩蓋。

- 每次主列表請求至多原始一次 list 加恢復一次 list，沒有遞迴重試。
- 新 manager 使用 `connectShareOnce`，不再走 `connectShare` 的 echo 失敗後第二次 connect。首次連線沒有新增自動重試；libsmb2 的位址候選處理不變，因此不宣稱底層只建立一個 socket。
- 恢復後從 offset 0 建立新快照、取代舊項目；不把舊分頁 offset 接到新目錄排序。原一般導航快取及明確重新整理入口保留。
- 父目錄、標籤及 Finder 能力探測不各自發起目錄恢復循環。主列表成功後可按原功能重新執行適用的附屬讀取。Build66 媒體讀取採獨立、分類更窄的播放來源恢復，不擴大此 runner 的預算。
- 播放器仍借用來源時，一般失效仍不得由主列表替換該 provider。Build66 僅對已完成播放專用退役並確認排空的 `retiredByPlaybackRecovery` 放行播放中補頁；舊來源此時已排空且不再接受播放讀取，播放恢復另行建立私有 fresh 來源，目錄可獨立走原 runner 接手；marker 不代表 fresh 已成功或發布。普通 retired、清理失敗或尚未排空均不取得例外，registry／generation／provider 身分檢查不變。目錄恢復不重送影格，也不新增背景連線保活。

## 錯誤來源與分類

`SMB2OperationFailure` 在失敗邊界保存固定來源：`serviceInvalidated`、`submission`、`response`、`wait`、`contextUnavailable`，只帶該邊界有定義的數字碼。service 的通用 -1 不再反轉成 POSIX EPERM；它只證明 context 已不可再用，不代表確定 TCP 斷線、伺服器故障或退出原因。

正常 response 的 EPERM／EACCES 保留拒絕，ENOENT／ENOTDIR 保留不存在；固定版本 libsmb2 將 LOGON_FAILURE 映為 ECONNREFUSED，因此 response 的此碼保留認證失敗。來源不明的 EPERM／timeout 可以獲一次新的唯讀嘗試，但不標為已證實斷線。ENETRESET／EPIPE 等 response 也可能是不同伺服器狀態，維持未分類 session 失敗。

真正目錄 opendir／query 路徑已在 C 層把部分 NTSTATUS 轉為 errno，無法還原全部 server cancel 或認證子類。人工 raw-NTSTATUS 分類測試不代表真實目錄保有全部原狀態。明確 Swift Task 取消優先，取消後不發起新的恢復步驟。

## 排空、取消與舊回呼

`DirectoryReadRecovery` 是主列表實際使用的狀態核心。它持有每個來源 key 的 provider 身分及 creation／replacement ticket；在可執行下一步前後核對取消、導航 generation、來源／credential revision 及 ticket。舊回呼只能清理自己的 candidate，不能移除或發布新擁有者的 session。

provider 先停止接受新的 page／tag／Finder／media 工作，再等待實際 await 的 lease 完成；Task 取消不提早釋放 lease。依賴隨後等 `operationCount` 歸零，包括原 completion handler 返回，才釋放本地 context。不能把 continuation 返回、providerExited 或 taskExited 當作底層排空。

清理未完時同 key 保持 busy；清理失敗則隔離該 key，不能累積新連線。過期 candidate 仍須清理，這一步不因導航取消而提早放行。恢復不新增遠端 disconnect RPC；若一般 disconnect 已先啟動，加入同一清理工作並等待，失敗仍傳回恢復流程。其他來源不因該 key 的隔離而一併鎖住。

一次預算是嘗試次數上限，不是硬時間上限。保留 manager 的 15 秒設定、原 poll 間隔及比較方式，等待鎖、queue、其他工作或連線可能更久；沒有 timeout race 強行釋放，也沒有重播舊 timeout 實驗或變更 manager queue 排程。

## 每個 socket 的訊號防護

Darwin 的每個新建 SMB client TCP socket 在 connect 及協定寫入前設定 `SO_NOSIGPIPE=1`；IPv4、IPv6 及後續位址候選均經過同一入口。設定失敗時保留原 errno、關閉 socket 並回報錯誤，不繼續使用無防護 socket。

此防護使該 socket 的 broken-pipe 寫入不以 SIGPIPE 終止程序，並不自行修復連線，也不保證上層立即或原樣收到 EPIPE。未修改全程序 signal disposition、SMB 協商、簽章或加密。

既有來源與本機 syscall／signal 檢查能證明防護路徑，卻沒有匹配的實機 signal 或終止堆疊證明原退出由 SIGPIPE 造成。不能把缺少回呼日誌或使用者接受結果當成根因證明。機制依據：[Apple 網路常見問題](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/NetworkingOverview/CommonPitfalls/CommonPitfalls.html)、[setsockopt](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setsockopt.2.html)。

## 依賴與局部 C handle 保護

AMSMB2 上游仍為 4.0.3，revision `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`；libsmb2 仍為 `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03`。SwiftPM 與兩個 Xcode 入口共用本地 `Dependencies/AMSMB2`，取代遠端 AMSMB2 pin。來源、修改檔及兩份 patch 的 SHA-256 見 [provenance](../Dependencies/AMSMB2-provenance.json)。

第一份 patch 為每個 socket 的 SO_NOSIGPIPE；第二份為 typed error origins、單次連線入口、本地排空退役及回呼／C handle 生命週期保護：

- 兩個 async wrapper 的 callback pointer 儲存範圍涵蓋 submit、wait 與失敗清理。wait 失敗時，仍在 context lock 且 callback 資料有效的範圍內 invalidate，再拋回原錯誤。
- 目錄開啟至 Swift 值轉換、file handle 建立／ID／seek／metadata，以及單次 read／pread 的大小及資料存取，補在相同 context lock 保護範圍內。

這些是特定使用點的生命週期修補，不代表整個依賴或所有多請求交錯已具併發安全保證。Build66 沒有再改此依賴層，也沒有採用新的 SMB queue 或全域序列化；播放專用 typed 介面與一次來源重讀位於 Vista adapter／wrapper，見播放中斷恢復文件。第三方來源與授權保留，見 [授權與貢獻](授權與貢獻.md)。

## 實測證據與停止界線

Build64 的匿名時間線包含 399 筆連續序列，屬同一次程序生命週期；其中 4 次 service 失效後，均看到舊 provider 退役、新 session、cache miss、列目錄成功及 UI 套用。各次從失效到套用約 114–215 ms，證明這四次完成了新的列舉，而不是只顯示舊快取；此為該輪觀測，不是通用延遲保證。

使用者已接受切目錄退出修正。另一次沒有匹配 crash／終止證據的回 Home 事件依使用者指示停止追查，不列為已修復，也不自動恢復研究。Build64 當時未驗收播放恢復，且正式整合保留 background-only、排除該安裝測試版的 inactive 提早暫停，當時的重新組合未再做實機測試。之後 Build66 摘戴後手動續播、離開影片、換片及切目錄已另經使用者接受，不能仍將此情境當作未解；見 [播放中斷恢復](播放中斷恢復.md)。所有摘戴／退出、失效網路與廣泛併發安全仍不在本項證據範圍內。

本機測試以實際恢復核心、序列手動完成的 fake manager／callback／lease 及依賴人工案例驗證一次預算、取消、過期回呼、排空、失敗隔離、錯誤分類及分頁重置。現行重驗結果統一見 [已驗收基底](已驗收基底.md)，匿名事件語義與限制見 [生命週期診斷](生命週期診斷.md)。
