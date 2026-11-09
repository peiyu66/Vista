# AMSMB2 邊界驗證來源

此套件以相對symlink引用本專案實際AMSMB2／libsmb2，不編入上游AMSMB2Tests。目前來源包含24項／2 suites（原18項加6項persistent-handle），其中原18項有30個參數案例；靜態來源合約為34項。

**Build104正式promotion不執行此runtime套件。** 過去18／24項成功只作歷史收據，不冒稱本輪新通過。套件含人工PDU、callback排空與本地handle清理，即使無NAS也不能簡稱完全沒有排程驗證；未經核實範圍不得重跑或改名執行。

本輪只執行 `python3 tools/AMSMB2BoundaryTests/verify_contracts.py` 的字串／hash合約核對，可用 `--output` 指定收據位置。dependency-baseline.json保留原libsmb2與上游manifest hash；不將靜態34項視為runtime安全證明。

相對別名AMSMB2Swift與SMB2C保持symlink，不提交展開副本。現行來源與限制見 [已驗收基底](../../docs/已驗收基底.md)。不連NAS、不跑上游網路、SMB／Admission／受限並發測試。
