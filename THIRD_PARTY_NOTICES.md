# 第三方来源及许可

## MeloX

Flowflow 包含 [MeloX](https://github.com/youshen2/MeloX) 的代码及其修改，适用 GNU GPL version 3，许可证文本见 [LICENSE](LICENSE)。原版的本地基准为 MeloX 0.3.0 macOS 源码；当前项目将相关功能整理为独立悬浮歌词应用，并增加播放器联动、设置与后续修复。完整修改历史并未在本地保留。

## MediaRemote Adapter

[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)，Copyright © 2025 Jonas van den Berg and contributors，BSD 3-Clause。源码及许可声明见 [Vendor/mediaremote-adapter](Vendor/mediaremote-adapter)；构建后的应用也包含许可文本。

## QRC 解码相关实现

- [valenbine/LRC-GET](https://github.com/valenbine/LRC-GET) 的 `src/des-helper.js`，本项目参考快照 `2cc0e67dcfc567a122ebb953ef696783a6760d17`，MIT。适配版本为 `Resources/qrc-des.js`；来源说明与许可证见 [Vendor/QRCDecoder](Vendor/QRCDecoder)。
- [WXRIW/QQMusicDecoder](https://github.com/WXRIW/QQMusicDecoder)，Copyright © 2023 WXRIW，MIT；许可文本为 `Resources/LICENSE-QQMusicDecoder.txt`。
- [SuJiKiNen/LyricDecoder](https://github.com/SuJiKiNen/LyricDecoder)，Copyright © 2019 SuJiKiNen，MIT；许可文本为 `Resources/LICENSE-LyricDecoder.txt`。

## 系统组件

应用使用 macOS 提供的框架和工具。它们由操作系统提供，不作为本仓库的开源代码重新分发。

## 上游其他组件的说明

MeloX 上游还列有 [PV Tool](https://github.com/DanteAlighieri13210914/pv-tool) 和 [BeatNet](https://github.com/mjhydri/BeatNet) 的独立许可信息：PV Tool 的相关内容使用非商业许可；MeloX 说明其 BeatNet 通用模型及 Core ML 转换版本采用 CC BY 4.0，具体以各自许可文本和来源说明为准。

对本次 Flowflow 1.0.98 macOS 构建，未在随包文件中发现 PV Tool 模板、BeatNet 模型或相应运行实现。继承的中文本地化文件仍含有关文字，因此保留此来源说明；这不代表上述模板和模型已随 Flowflow 分发，也不是对所有代码权利状态的最终结论。
