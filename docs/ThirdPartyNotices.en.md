# Third-party copyrights and licenses

[中文](../THIRD_PARTY_NOTICES.md)

[Back to Home](../README.en.md)

Vista’s own code is licensed under the [MIT License](../LICENSE). The components below retain their own licenses. We thank their authors and contributors. The original license documents and corresponding source files contain the full terms and individual copyright notices.

This list covers components used by Vista. See the [component and distribution review](development/元件與分發核對.md) for the status of their integration into the public source and distribution materials.

| Component | Reviewed version or source | Copyright and license references |
| --- | --- | --- |
| AMSMB2 | 4.0.3, `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`, with Vista patches | Its authors and individual file copyright holders; [supplemental patch](https://github.com/peiyu66/Vista/blob/main/DependencyPatches/AMSMB2-4.0.3-operations-drained-178.patch), [original LICENSE](https://github.com/peiyu66/Vista/blob/main/Dependencies/AMSMB2/LICENSE), [source and modifications](https://github.com/peiyu66/Vista/blob/main/Dependencies/AMSMB2-provenance.json). Swift file headers contain MIT notices; the project linked with libsmb2 uses LGPL 2.1 and must not simply be described as MIT. |
| libsmb2 | `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03`, with patches | Ronnie Sahlberg and individual file authors; [COPYING scope](https://github.com/peiyu66/Vista/blob/main/Dependencies/AMSMB2/Dependencies/libsmb2/COPYING), [LGPL 2.1](https://github.com/peiyu66/Vista/blob/main/Dependencies/AMSMB2/Dependencies/libsmb2/LICENCE-LGPL-2.1.txt). Library and include files use LGPL 2.1-or-later; examples have separate BSD-2-Clause terms. |
| Apple Material | Adapted from Displaying a stereoscopic image | Apple Inc.; [complete MIT notice](https://github.com/peiyu66/Vista/blob/main/VistaApp/Resources/Apple-Stereo-LICENSE.txt). The sample photographs are not included. |
| libwebm mkvparser | 1.0.0.32, `f2a982d748b80586ae53b89a2e6ebbc305848b8c` | Google Inc. and the [authors](third-party-licenses/libwebm-AUTHORS.txt); [BSD-3-Clause](third-party-licenses/libwebm-LICENSE.txt), [additional patent grant](third-party-licenses/libwebm-PATENTS.txt). |
| GPAC ISO-BMFF subset | 26.07; source snapshot directory labeled 26.07.0 | GPAC and individual source authors; [LGPL 2.1](third-party-licenses/GPAC-LGPL-2.1.txt), [supplemental source notices](third-party-licenses/GPAC-supplemental-notices.txt). The version conditions and additional notices in each original file apply. |
| libVLC and selected modules | 4.0.0-dev; `f7caf7922478f6cb7f1654b813d0c462d3e86f4a` with fixed compatibility and Vista patches | VideoLAN, VLC authors, and individual file authors; [LGPL 2.1](third-party-licenses/VLC-LGPL-2.1.txt). Other VLC modules may use different licenses; the libVLC name does not determine the license of every plugin. |
| FFmpeg libavcodec / libavutil | 9.0, configured for AAC audio decoding | FFmpeg developers and individual source authors; [license scope](third-party-licenses/FFmpeg-LICENSE.md), [LGPL 2.1](third-party-licenses/FFmpeg-LGPL-2.1.txt). The retained configuration does not enable GPL, nonfree, or version3. |
| libebml | 1.4.6 | Steve Lhomme and individual source authors; [LGPL 2.1-or-later](third-party-licenses/libebml-LGPL-2.1.txt). |
| libmatroska | 1.7.2 | Steve Lhomme and individual source authors; [LGPL 2.1-or-later](third-party-licenses/libmatroska-LGPL-2.1.txt). |
| UTF8-CPP / utfcpp | 3.2.5, headers used by VLC | Copyright 2006 Nemanja Trifunovic and individual file authors; [Boost Software License 1.0](third-party-licenses/utfcpp-Boost-1.0.txt). |
| lzokay | Source included in the VLC commit above; no separate version specified | Copyright (c) 2018 Jack Andersen; [MIT](third-party-licenses/lzokay-MIT.txt). |

Apple system frameworks, libc++, and system zlib/iconv are provided by the platform. The SDK and system frameworks are not Vista’s own MIT-licensed code. A fixed VLCKit patch series is used to prepare the VLC source; the VLCKit wrapper is not linked. Reproducing the complete source also requires retaining that patch series and its original notices.

License obligations, relinking materials, in-app notices, and store requirements must be checked for the actual distribution method. See the [distribution review and outstanding items](development/元件與分發核對.md#分發前仍須完成).

[Additional notices from compiled sources](third-party-licenses/Native-supplemental-notices.txt) · [libsmb2 MD4 notices](third-party-licenses/libsmb2-supplemental-notices.txt)
