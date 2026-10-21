# deepseek-harness · 需求规格书（SPEC v1）

> 需求来源：主人 2026-10-21 原话。本文件是全部后续开发与子代理写码的唯一依据，随研究结果滚动更新。

## 一、一句话定位
iOS 单机 App：**豆包网页 → OpenAI 兼容 API 网关 + AI 助理（OpenClaw 功能面）+ 内置 Alpine Linux 终端（iSH）+ 无限画布**，界面一比一还原 deepseek-ai/deepseek-harness，App 名与图标直接用它的。

## 二、硬性需求（逐条对应主人原话）
1. **豆包网页转 API**（参考 doubao2API ×2 / doubao-free / infinite-canvas）：
   - API 能用的功能全部要有：**对话（流式）、图片生成、视频生成、语音**
   - 本地起 OpenAI 兼容服务（/v1/models、/v1/chat/completions 流式+非流式、图像/音频/视频端点），第三方 App（含 Minis）填 Base URL 即可用
2. **OpenClaw（openclaw/openclaw）功能必须全部要有**：渠道接入、agent、工具、技能/插件、记忆、定时任务、Web 控制台、网关 API、安全机制等（功能矩阵见 research/openclaw-features.md，落地时逐项映射）
3. **内置 iSH（ish-app/ish）**：不内置就无法装软件包、跑不了 Python；AI 干活必须用 → 终端 Tab 内嵌 Alpine（apk + python3），另打包 linux-command（jaywcjlove/linux-command）中文命令手册供 help/AI 查询
4. **界面 = deepseek-ai/deepseek-harness 一比一**：图标不改、名字不改、配色布局尽量逐像素还原（规格见 research/harness-ui.md）

## 三、架构（5 Tab）
```
HarnessApp (TabView)
├── Chat        # deepseek-harness 风格对话；豆包模型流式；图片/视频/语音消息渲染；工具调用气泡
├── Canvas      # 无限画布（infinite-canvas 借鉴）：卡片（文本/图/视频/音频）平移缩放钉选，AI 产物一键上画布
├── Terminal    # iSH Alpine 终端（apk/python3）+ linux-command 手册
├── Agents      # OpenClaw 功能面：渠道（Telegram/Discord/Webhook）、技能、记忆、定时任务
└── Settings    # 豆包账号（Cookie）管理、网关开关/端口/Key、模型清单、日志
```

## 四、模块清单（Swift 文件规划）
- `DoubaoKit`：豆包网页协议客户端（鉴权/聊天SSE/图/视频/语音）→ 内部统一 OpenAI 兼容接口
- `GatewayServer`：NWListener 本地 HTTP 服务（0.0.0.0，Bearer Key），OpenAI 兼容全套端点
- `AgentCore`：会话/工具循环/记忆/技能加载/定时任务（OpenClaw 移植）
- `ChannelsKit`：Telegram Bot polling、Discord WS、Webhook 接收（后台音频保活）
- `TerminalKit`：iSH 引擎桥接（或降级：内嵌 CPython + 沙盒 shell）
- `CanvasKit`：无限画布视图（UISCrollView 手势 + 卡片层）
- `UI`：deepseek-harness 主题（色板/字体/组件）+ 各屏

## 五、版本路线（每版必须可构建出 IPA）
- v0.1 ✅骨架可构建：5 Tab 空壳 + 主题占位 + CI 绿灯
- v0.2 豆包对话通：Cookie 配置 → 网关 → Chat 流式
- v0.3 图片/视频/语音三件套
- v0.4 OpenClaw 面：工具循环 + 记忆 + 定时 + 渠道
- v0.5 iSH 终端 + python + 手册
- v0.6 无限画布 + 1:1 UI 打磨

## 六、铁律（来自域⑥实战手册）
- 资源先于 xcodegen generate；禁 tail 截断错误；禁 || true 假成功
- 公开仓库禁明文 Key（Secrets → plist）
- 每版交付必跑核验清单（二进制存在/特征串/md5）
- push SSL 假失败先查远端 HEAD；真失败走 Data API 重放

## 七、研究文档索引（research/）
- `doubao-protocol.md` 豆包协议全规格（特工1）
- `openclaw-features.md` OpenClaw 功能矩阵（特工2）
- `harness-ui.md` + `assets/` Harness UI 规格与图标（特工3）
- `ish-integration.md` iSH 内嵌方案 + linux-command 打包（特工4）
