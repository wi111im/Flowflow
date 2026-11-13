# Flowflow

Flowflow 是 macOS 上的悬浮歌词工具。它读取网易云音乐、QQ 音乐或 Apple Music 的播放状态，显示与播放进度同步的歌词。

本项目为非官方项目，与上述播放器及其运营方没有隶属或授权关系。

## 功能

- 显示当前歌词、下一句和翻译，并支持逐字高亮、轻微漂浮与发光效果。
- 调整字体、字号、字重、颜色、透明度、位置和歌词时间；支持搜索和手动匹配歌词。
- 通过悬浮歌词和状态栏进行播放控制，并跟随支持的播放器启动或退出。
- **部分歌曲延迟自修改**：应用包含一份预设的歌曲歌词时间偏移表，具体条目见 `Resources/DefaultSongOffsets.plist`；也可在应用内针对歌曲自行调整。

## 运行与构建

当前版本面向 Apple Silicon Mac，需要 macOS 15 或更高版本。播放信息来自已安装并运行的受支持播放器；在线歌词是否可用取决于歌曲和服务状态。

[下载 Flowflow 1.0.98（macOS，Apple Silicon）](https://github.com/wi111im/Flowflow/raw/refs/heads/main/downloads/Flowflow-1.0.98-macOS-arm64.zip)

从源码构建需要 Xcode 命令行工具和 Python 3：

```sh
python3 build.py
```

脚本构建 `Flowflow.app`、进行本机临时签名并运行项目自测。临时签名不是 Apple Developer ID 签名；向其他 Mac 分发时，系统可能要求额外的安全验证。

## 许可与来源

Flowflow 官方版本免费提供。GPLv3 允许他人对符合许可的复制、修改或分发行为收费；本声明不限制这些权利。第三方分发者不得虚假声称其版本由 Flowflow 官方发布、获得官方背书，或与项目维护者存在实际不存在的关联。

Flowflow 包含基于 [MeloX](https://github.com/youshen2/MeloX) 修改的代码，主体代码按 [GNU General Public License version 3](LICENSE) 发布。复制、修改或分发本项目时，请遵守该许可证关于提供对应源代码、保留版权声明和按相同许可证分发等条件；具体条款以 `LICENSE` 为准。

第三方代码、资源和模型继续适用各自的许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。上游 MeloX 对 PV Tool 和 BeatNet 分别有独立许可说明；本次对 Flowflow 1.0.98 macOS 构建的检查未发现 PV Tool 模板或 BeatNet 模型文件。本项目的部分继承的本地化文字仍提及它们；这不表示它们的许可证覆盖本项目的其他部分。

源代码包含重建本版本所需的构建脚本、程序代码和随应用发布的资源；音乐、封面和在线歌词仍属于各自权利人，不因本项目的代码许可而改变权利归属。

## 免责声明

本项目出于学习与研究目的开发。Flowflow 不对 GPLv3 覆盖的主体代码附加额外限制；第三方代码、资源和模型仍按各自许可证使用。使用者应自行遵守所在地法律法规、所使用音乐服务的条款以及音乐内容的版权要求。

项目按许可证所述不提供担保；因使用本项目产生的风险由使用者自行承担。

下载后请于 24 小时内删除。此条仅为建议，不作为使用、复制、修改或分发的条件，也不限制 GPLv3 或其他适用许可证赋予的权利。
