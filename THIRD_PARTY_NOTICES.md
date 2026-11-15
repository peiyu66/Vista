# 第三方版權與授權

Vista 自有程式採 [MIT License](LICENSE)。下列元件不因與 Vista 一起使用而改採 Vista 的授權。感謝各上游作者與貢獻者；完整條件及個別著作權以原始授權文件和對應來源檔為準。

此清單同時說明公開來源106及已使用的178；不表示表內所有元件都已放入本儲存庫的建置，也不是新的安裝包。精確範圍見[元件與分發核對](docs/元件與分發核對.md)。

| 元件 | 已核對版本／來源 | 版權與授權入口 |
| --- | --- | --- |
| AMSMB2 | 4.0.3，`1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`，含 Vista 修補 | 作者及各檔權利人；[178補充修補](DependencyPatches/AMSMB2-4.0.3-operations-drained-178.patch)、[原始 LICENSE](Dependencies/AMSMB2/LICENSE)、[來源及修改](Dependencies/AMSMB2-provenance.json)。Swift 檔頭有 MIT，整體連結 libsmb2 的專案採 LGPL 2.1，不能僅稱 MIT。 |
| libsmb2 | `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03`，含修補 | Ronnie Sahlberg 及各檔作者；[COPYING 範圍](Dependencies/AMSMB2/Dependencies/libsmb2/COPYING)、[LGPL 2.1](Dependencies/AMSMB2/Dependencies/libsmb2/LICENCE-LGPL-2.1.txt)。lib/include 為 LGPL 2.1-or-later，examples 另依 BSD-2-Clause。 |
| Apple Material | Displaying a stereoscopic image，Vista 改編材質 | Apple Inc.；[完整 MIT 聲明](VistaApp/Resources/Apple-Stereo-LICENSE.txt)，未納入範例照片。 |
| libwebm mkvparser | 1.0.0.32，`f2a982d748b80586ae53b89a2e6ebbc305848b8c` | Google Inc. 及[作者](docs/第三方授權/libwebm-AUTHORS.txt)；[BSD-3-Clause](docs/第三方授權/libwebm-LICENSE.txt)、[額外專利授權](docs/第三方授權/libwebm-PATENTS.txt)。 |
| GPAC ISO-BMFF 子集 | 26.07；來源快照目錄標示26.07.0 | GPAC／各來源檔作者；[LGPL 2.1](docs/第三方授權/GPAC-LGPL-2.1.txt)，所用來源按檔頭為2.1或更新版本。 |
| libVLC 與採用模組 | 4.0.0-dev；`f7caf7922478f6cb7f1654b813d0c462d3e86f4a` 加固定相容／Vista修補 | VideoLAN、VLC authors 及各檔作者；[LGPL 2.1](docs/第三方授權/VLC-LGPL-2.1.txt)。VLC 專案另有不同授權模組，不能從 libVLC 名稱推定全部外掛授權。 |
| FFmpeg libavcodec／libavutil | 9.0，AAC 音訊解碼配置 | FFmpeg developers 及各來源檔作者；[授權範圍](docs/第三方授權/FFmpeg-LICENSE.md)、[LGPL 2.1](docs/第三方授權/FFmpeg-LGPL-2.1.txt)。已保存配置未啟用 GPL、nonfree、version3。 |
| libebml | 1.4.6 | Steve Lhomme 及各來源檔作者；[LGPL 2.1-or-later](docs/第三方授權/libebml-LGPL-2.1.txt)。 |
| libmatroska | 1.7.2 | Steve Lhomme 及各來源檔作者；[LGPL 2.1-or-later](docs/第三方授權/libmatroska-LGPL-2.1.txt)。 |
| UTF8-CPP / utfcpp | 3.2.5，VLC 相依標頭 | Copyright 2006 Nemanja Trifunovic 及各檔作者；[Boost Software License 1.0](docs/第三方授權/utfcpp-Boost-1.0.txt)。 |
| lzokay | 納入上述 VLC commit 的來源檔，未另指定版本 | Copyright (c) 2018 Jack Andersen；[MIT](docs/第三方授權/lzokay-MIT.txt)。 |

Apple 系統框架、libc++、系統 zlib／iconv 由平台提供；不把 SDK 或系統框架列成 Vista 自有 MIT 程式。VLCKit 的固定修補系列用於 VLC 來源準備，沒有連結 VLCKit wrapper；完整來源重現仍需保留該系列修補與原聲明。

授權、可重新連結材料、App 內聲明及上架條件仍須按實際分發方式逐項完成；詳[分發核對與未完成項目](docs/元件與分發核對.md#分發前仍須完成)。
