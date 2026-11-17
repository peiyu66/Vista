# 原生基底建置與重新連結

原生材料以 Vista 178 為基底；已整合 [194 直接恢復](../docs/development/直接恢復194.md)、[204 三筆在途與 HEVC preroll 省略](../docs/development/解碼恢復204.md)，及使用者驗收的 [206 保留解碼狀態向前恢復](../docs/development/向前恢復206.md)。目前上架候選為 1.0（210），保留 207 的播放策略並整合使用者確認的 209 雙語介面、關於頁及聲明；見[候選核對](../docs/development/上架候選210.md)。音訊儲備與額外實驗日誌未納入。已完成修改庫重新連結；這不等於所有分發義務或 App Store 審核已完成。

## 環境

需要 Apple Silicon Mac、含 visionOS SDK 的完整 Xcode，以及 Python 3.12 或以上、CMake、pkg-config、GNU Autoconf／Automake、GNU libtool 和 GNU m4。已使用 Xcode 27.2、Autoconf 2.73、Automake 1.18.1 驗證建置工具。這些是主機建置工具，不會一起連結進 App。

建置工具須在 `PATH`；自備工具可指定 `VISTA_BUILD_TOOLS=/path/to/tools/bin`。GNU libtool 的 `libtoolize` 可透過 Homebrew 的 `libtool/libexec/gnubin` 提供；GNU m4 亦須可找到。腳本會查找 Apple Silicon Homebrew 的常用位置，但不會安裝工具或變更系統設定。其他工具位置可透過 `PATH`、`M4`、`ACLOCAL_PATH` 指定。缺少工具時會在原生建置前停止。

## 從固定來源建置

從儲存庫根目錄執行：

```sh
python3 NativeBuild/build.py all
```

`archives.json` 固定來源封存的 SHA-256，先核對再解開。VLC 套用 `vlc-base-compat.patch`，`overlay/` 保存 Vista 實際修改單元與其相依標頭。FFmpeg 使用 AAC 子集，GPAC 使用 ISO-BMFF 子集。`engine/` 包含 Vista producer、parser 生成器與所需 libwebm 來源。

建置只產生未簽署 App：`.build/release/Build/Products/Release-xros/Vista.app`。不會安裝或啟動裝置。SDK、系統 framework 和簽署憑證不包含在來源包內。

## 修改與重新連結

可以修改解開後的相依來源及 `NativeBuild/overlay/inputs/` 中的 Vista 修改單元。變更 overlay 輸入後，明確選用：

```sh
python3 NativeBuild/build.py all --allow-modified-sources
```

該選項只略過 overlay 輸入與原基準雜湊相等的限制；封存完整性仍核對。overlay 會取代基底庫的同名編譯單元，若修改屬於 overlay 中的檔案，應修改 overlay 版本。只需重新連結已準備好的庫時：

```sh
python3 NativeBuild/build.py app
```

產物與執行紀錄寫入 `NativeBuild/receipt.json`、`NativeBuild/dependencies/logs/`。來源／二進位雜湊可能因工具鏈、路徑及生成資訊不同而變化，不宣稱位元完全一致。修改庫的可連結性、實機執行與音畫品質是不同驗證項目；本建置命令不完成後兩項。

原始元件條款及著作權保持，見[第三方聲明](../THIRD_PARTY_NOTICES.md)及來源檔。此文件提供技術操作，不替代完整授權條件或分發核對。

中間庫的授權範圍與最終 App 不可混同；FFmpeg CRC 個案及分發界線見[元件與分發核對](../docs/development/元件與分發核對.md)。原始碼封存保留所有上游授權，包括未進入最終 App 的來源條款。
