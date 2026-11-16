# 官方來源

- Repository: https://github.com/webmproject/libwebm
- Tag: libwebm-1.0.0.32
- Annotated tag object: b148cb3a1fced8ef285169dbe1b1b01a71b5dd64
- Commit: f2a982d748b80586ae53b89a2e6ebbc305848b8c
- 來源核對日期：2026-11-03。

只複製 `mkvparser/mkvparser.cc`、`mkvparser/mkvparser.h`、`common/webmids.h`；內容未修改。沒有 muxer、codec、範例工具或外部 decoder。原始 LICENSE.TXT、PATENTS.TXT、AUTHORS.TXT 完整保留；SHA256SUMS 列出這六份原始檔。

來源為官方鏡像與固定 commit，不宣稱標籤有經作者簽章驗證。此副本只供隔離原型；若日後加入 App，需另將相關聲明納入實際分發資源，不能僅留在開發目錄。


隔離原型的建置腳本現會從固定官方檔生成衍生 translation unit：增加 ParserBudget.hpp include，將精確 44 處 nothrow new 改成 parser 專屬 tag overload。原始副本與 SHA256SUMS 不變，衍生檔保留上游聲明；此修改可由 `Experiments/MKVParser/run.py` 重建與稽核，不宣稱衍生二進位未經修改。App 尚未連結此衍生元件。
