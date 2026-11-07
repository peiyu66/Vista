# AMSMB2 錯誤與生命週期本機驗證

從儲存庫根目錄執行：

```sh
swift test --package-path tools/AMSMB2BoundaryTests --no-parallel -j 4
```

獨立套件以相對符號連結編譯本專案實際AMSMB2與libsmb2來源，不複製演算法、不解析上游網路測試依賴。需macOS及既有Swift工具鏈。18項測試／30參數案例，涵蓋service sentinel、提交／回呼錯誤來源、原始PDU狀態、過期nterror隔離、缺失context、callback儲存範圍及本地file handle失效後存取。

只使用人工回呼、本地pipe及未連線context；不連NAS、不執行SMB請求、poll/timeout或多請求併發驗證。不要以執行整個上游AMSMB2Tests替代此精選套件。測試通過不代表所有真實網路交錯或原退出根因已獲證明。

另外可執行 `python3 tools/AMSMB2BoundaryTests/verify_contracts.py` 做26項窄範圍來源合約檢查。預設結果寫入本套件的 `.build/source-contracts.json`，可用 `--output` 指定其他結果檔。dependency-baseline.json只保存相對檔名及公開依賴雜湊，固定Build63的libsmb2局部防護基線與上游manifest；不包含私人檔案。來源字串檢查不能取代行為測試。
