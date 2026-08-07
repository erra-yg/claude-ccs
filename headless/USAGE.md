# claude-ccs 使用教程

`claude-ccs` 让你用**一条命令**把 Claude Code（cc）接到任意 OpenAI 兼容的大模型供应商，并且**绝不改写 `~/.claude/`** 下的任何文件。

它在你本机起一个 headless 代理（Anthropic↔OpenAI 协议翻译 + 故障转移），cc 经环境变量指向这个代理；供应商选择存在代理自己的数据库里，与你 `~/.claude/settings.json` 完全隔离。

---

## 1. 它解决什么问题

- 你已有一套 zsh 启动器（如 `claude-glm`、`claude-kimi`），各走各的 env，互不干扰。
- 你想把 **OpenAI 协议**的供应商（如 opencode Go、DeepSeek、OpenRouter 等）也接进 cc——但 cc 只会说 Anthropic 协议，需要翻译。
- 你**不想**让任何工具覆盖你手调的 `~/.claude/settings.json`（hooks/statusline/plugins）。

`claude-ccs` = 翻译代理 + 永不碰 `~/.claude` + 一条命令启动。

---

## 2. 前置条件

- WSL / Linux，zsh（`~/.zshrc`）。
- 已装 Claude Code CLI（`claude`）。
- 一个 OpenAI 兼容供应商的 API key。
- 联网（首次构建需下载 Rust 依赖）。

---

## 3. 安装（新机一键）

```bash
git clone https://github.com/erra-yg/claude-ccs ~/claude-wksp/cc-switch-headless
cd ~/claude-wksp/cc-switch-headless
./install-claude-ccs.sh
```

`install-claude-ccs.sh` 会自动：装 build 工具链 → 装 Rust（若缺）→ 构建 cc-switch → 把 `claude-ccs` 接入 `~/.zshrc` → 建 `~/.config/ccs-providers/`。首次构建约 5–10 分钟。

装完：
```bash
source ~/.zshrc        # 或开新终端
```

> 你也可以把仓库网址直接告诉 Claude Code，让它帮你 `git clone` + 跑 `install-claude-ccs.sh`。

---

## 4. 核心概念：供应商 profile

每个供应商是 `~/.config/ccs-providers/<名字>/` 下的几个小文件：

| 文件 | 必需 | 内容 |
|---|---|---|
| `base-url` | 是 | OpenAI 兼容端点，**不要带末尾 `/v1`**（代理会自己拼 `/v1/chat/completions`） |
| `auth-token` 或 `keyfile` | 是 | `auth-token` = key 本身（**推荐**，profile 自包含）；`keyfile` = 存 key 的文件路径（备选，指向外部密钥文件） |
| `model` | 否 | model id |

> 建议把 `auth-token`（或 `keyfile` 指向的文件）`chmod 600`。`base-url` 若带了 `/v1`，代理会拼成 `/v1/v1/...` 导致失败。

---

## 5. 首次配置：以 opencode Go 为例

opencode Go 是 opencode.ai 的低价订阅，OpenAI 兼容端点 `https://opencode.ai/zen/go/v1`，可用 `deepseek-v4-flash`。

```bash
mkdir -p ~/.config/ccs-providers/opencode
echo 'https://opencode.ai/zen/go' > ~/.config/ccs-providers/opencode/base-url
echo 'deepseek-v4-flash[1m]'          > ~/.config/ccs-providers/opencode/model
echo '你的_API_KEY'                 > ~/.config/ccs-providers/opencode/auth-token   # key 本身，直接放进 profile
chmod 600 ~/.config/ccs-providers/opencode/auth-token
```

注意 `base-url` 是 `https://opencode.ai/zen/go`（**不带** `/v1`）。

> **1M 上下文**：model 末尾的 `[1m]` 让 Claude Code 按 1M 窗口管理会话；代理在发往上游前会**自动剥掉 `[1m]`**，opencode 收到的仍是合法的 `deepseek-v4-flash`。模型若不支持 1M 就别加这个后缀。

---

## 6. 日常使用

```bash
claude-ccs opencode          # 启动 cc，走 opencode Go
claude-ccs                      # 不带参数 → 列出已有 profile
claude-ccs opencode --print "hi"   # 额外参数原样传给 claude
```

第一次对某个名字运行时：自动建供应商→切到它→起代理→启动 cc。之后每次：切供应商→补全配置→确认代理在→启动 cc。

代理是 `setsid` 脱离启动的，**关终端不会死**；日志在 `~/.cc-switch-headless/proxy.log`。

---

## 7. 它在工作时做了什么

```
你的终端                cc-switch(本机, headless)              上游
─────────              ─────────────────────────              ─────
claude-ccs opencode
  └─ ANTHROPIC_BASE_URL ──┐
     =127.0.0.1:15721     ▼
                      ┌──────────────────────┐
                      │ 代理 :15721          │
                      │  Anthropic⇄OpenAI翻译 │── Bearer 真key ──▶ opencode Go
                      │  + 故障转移           │                  deepseek-v4-flash
                      └──────────────────────┘
   ~/.claude/settings.json ：全程不动（CC_SWITCH_HEADLESS）
```

cc 发 Anthropic `/v1/messages` → 代理翻成 OpenAI `chat/completions` 打上游 → 上游回 → 代理翻回 Anthropic 给 cc。

---

## 8. 加更多供应商

丢一个目录即可，例如 DeepSeek 官方：

```bash
mkdir -p ~/.config/ccs-providers/deepseek
echo 'https://api.deepseek.com' > ~/.config/ccs-providers/deepseek/base-url
echo 'deepseek-chat'            > ~/.config/ccs-providers/deepseek/model
echo '你的_API_KEY'             > ~/.config/ccs-providers/deepseek/auth-token
chmod 600 ~/.config/ccs-providers/deepseek/auth-token
claude-ccs deepseek
```

> `claude-ccs` 默认按 `openai_chat` 协议翻译。绝大多数 OpenAI 兼容网关都适用。

---

## 9. 故障转移（可选）

代理支持自动故障转移（熔断 + 队列），但启用是**交互式**的（要 TTY 确认），所以请在**真实终端**操作（不要在脚本里）：

```bash
# 加备用供应商到故障转移队列
CC_SWITCH_HEADLESS=1 CC_SWITCH_CONFIG_DIR=~/.cc-switch-headless \
  cc-switch failover add deepseek
# 启用（会交互确认）
CC_SWITCH_HEADLESS=1 CC_SWITCH_CONFIG_DIR=~/.cc-switch-headless \
  cc-switch failover enable
```

或直接进 TUI：`CC_SWITCH_HEADLESS=1 CC_SWITCH_CONFIG_DIR=~/.cc-switch-headless cc-switch`。

---

## 10. 排错

| 现象 | 排查 |
|---|---|
| `claude-ccs` 命令找不到 | `source ~/.zshrc` 或检查 `~/.zshrc` 里 `# >>> claude-ccs (headless) >>>` 块；确认 `$CCS_BIN` 路径存在 |
| `cc-switch binary not found` | 重跑 `./install-claude-ccs.sh` 重新构建 |
| cc 报 `401 Missing API key` | ① profile 里 key 没读到（检查 `auth-token`/`keyfile`）；② 极少数情况是代理协议没命中——确认 profile 的 `base-url` 不带 `/v1` |
| 代理没起来 | 看 `~/.cc-switch-headless/proxy.log`；手动 `CC_SWITCH_HEADLESS=1 CC_SWITCH_CONFIG_DIR=~/.cc-switch-headless cc-switch proxy serve` 看报错 |
| 想换供应商不生效 | `claude-ccs` 每次都重选当前供应商；若手动改过 DB，重跑一次 `claude-ccs <name>` |
| 端口 15721 被占 | 改 `$CCS_PORT`（在 `claude-ccs.zsh` 里）或停掉占用进程 |

---

## 11. 卸载

```bash
# 删代理状态
rm -rf ~/.cc-switch-headless
# 从 ~/.zshrc 删 claude-ccs 块（# >>> claude-ccs (headless) >>> 到 <<< 之间）
# 删仓库与 profile
rm -rf ~/claude-wksp/cc-switch-headless ~/.config/ccs-providers
```
你的 `~/.claude/` 本来就没被碰过，无需还原。

---

## 12. 注意

- `claude-ccs` 全程 `CC_SWITCH_HEADLESS=1`，**保证不写 `~/.claude`**。
- cc-switch 自身状态在 `~/.cc-switch-headless/`（可整体备份/迁移）。
- `claude-ccs` 对每个供应商用固定的 `openai_chat` 翻译，并做了一处 meta 归一化绕过上游的一个 camel/snake bug（详见仓库 `headless/README.md` 的 "Known issue"）。
