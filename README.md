# 离线媒体文件与分镜工作台

保留原AutoClip探测/静音检测/剪切拼接/SRT解析、复活影像脚本切段、数字人指标门禁、歌曲流程、录音容器校验、RMS语音活动检测及转写分段纠错/复核导出；不包含任何模型、原素材或发布器。

## 使用

Python 3.11+。在本目录建立独立虚拟环境：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python cli.py example.json
.venv/bin/python -m unittest discover -v
```

`example.json`从零编写，仅含虚构输入。可以显式提供自己的同结构JSON文件。输出默认为终端；`--output result.json`使用独占创建，避免覆盖已有结果。CLI失败退出码2。

## 数据与边界

不发现本机账号、不读取环境中的模型密钥、不发送消息、不请求远端数据。只处理调用方明确传入的文件、记录或参数。合成示例不代表任何实际业务结果。需要系统ffmpeg/ffprobe。未保留AI唱歌、声音克隆、数字人生成、公司模型/远程ASR、麦克风监听、实时翻译、账号与自动发布；不能宣称这些能力已迁移或通过真实性验收。WhisperRunner只作为需用户自备二进制/模型的原生适配库源码，不在默认CLI执行。

## 发布状态

本项目源码采用 MIT 许可证，见 LICENSE。依赖按各自上游许可使用，安装的依赖/模型/字体/媒体不随此源码目录分发。

## 组件接口

action：script、inspect、cut、srt、transcript、voice_activity、quality、progress。cut要求input本地文件和不存在的output，segments可提供[[开始秒,结束秒]]；缺省用静音检测。transcript接受segments及replace/split/merge/review编辑。voice_activity接受16kHz一维浮点samples。quality只评估输入指标；此处没有生成人脸/人声。

原生语音补充组件：AudioRecorder（显式输出目录的16kHz WAV录制）、WavInspector、TextPostProcessor（显式词典与选项）、HistoryStore（显式JSON路径，仅管理元数据）、WhisperRunner（显式二进制/模型）。全部已去掉原AppPaths/AppSettings依赖；不含模型、热键、焦点上下文、粘贴与LLM。只做编译与纯文本/合成WAV验收，未开启麦克风或运行录音UI。编译检查：`swiftc -typecheck native/*.swift`。

## 2026-11-08 协作修订

- 48kHz分块重采样、WAV填充块、唯一录音/转写输出及子进程管道边界已补回归。
- 文本后处理保留正常叠词，不因一句结束语删除整段正文；选项关闭时保持原文。
- 时间进度统一时区；音频能量包含最后不足一帧的数据。
- 完整原生回归需要macOS与Xcode；native_tests只测试纯逻辑，不启动录音或申请麦克风权限。

集合根目录 `verify_release.py --project personal-media-workbench` 可复跑测试和包内首次使用示例；Web实际交互的浏览器证据另记。原版本测试数是历史记录，本轮以集合验证报告为准。


### 待发布版联网边界

媒体探测只接受调用方明确指定的本地路径，拒绝网络URL。FFmpeg/ffprobe及音频解码输入只允许本地协议；多输入逐一设置。没有公司接口、模型API或自动下载。程序依赖调用方选择的本地工具和文件；自行替换可执行文件、修改代码或接入外部服务属于新的信任边界。依赖安装可能需要网络，区别于媒体处理运行。
