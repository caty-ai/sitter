# sitter

<div align="center">

[🇺🇸 English](README.md) ｜ [🇯🇵 日本語](README.ja.md) ｜ **🇨🇳 简体中文** ｜ [🇹🇭 ไทย](README.th.md)

![Sitter 品牌主视觉图：“SITTER — A WATCH POST FOR DELEGATED AI WORK”。夜晚的窗边，一只黑猫守望着由虚线相连的任务节点星座，其中一枚亮起警报红；旁边是一本打开的记录台账和一盏警报灯。这是在不拥有目标运行时的前提下守望被委派工作的隐喻；图片本身不代表任何依赖关系。](assets/readme/hero.png)

<h4>一个免费工具，替你守着那些交给 AI 或电脑去跑的长时间任务。</h4>

[![CI](https://github.com/caty-ai/sitter/actions/workflows/ci.yml/badge.svg)](https://github.com/caty-ai/sitter/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![npm](https://img.shields.io/npm/v/%40caty-ai%2Fsitter?logo=npm&label=npm)](https://www.npmjs.com/package/@caty-ai/sitter)
![bash](https://img.shields.io/badge/runtime-bash%203.2%2B-lightgrey?logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(WSL)-lightgrey)
![deps](https://img.shields.io/badge/dependencies-none-lightgrey)

[它是做什么的](#what) ｜ [你需要什么](#requirements) ｜ [快速开始](#start) ｜ [为什么安全](#safety) ｜ [了解更多](#more)

它会检查任务是否真的完成了、是不是悄悄停在了半路，<br>
以及你一直在等的那个回复是不是被遗忘了 —— 并且一定会告诉你。

**再也不会有任务不声不响地消失。**

🔧 [面向工程师的文档](docs/engineering.md)（英文） ｜ 📘 [详细规格](docs/reference.md)（英文）

</div>
<!-- repo-state:begin (generated; do not edit) -->
<p align="center"><sub>generation: <code>20f43b7</code> (2026-08-29T09:33:11Z) · verify: <a href="https://api.github.com/repos/caty-ai/sitter/commits/main">API HEAD</a> · <a href="./status.json">status.json</a></sub></p>
<!-- repo-state:end -->

---

<div align="center">

![35 秒终端演示。场景 1：交给 sitter 的任务正常完成，警报文件保持为空。场景 2：第二个任务中途陷入沉默，sitter 检测到卡死并将其停止，台账中并排留下两次运行（成功与失败）的全部事件。](assets/readme/demo.gif)

[更多演示](docs/engineering.md#demos)（英文） — 卡死检测详解、零依赖版本、回复追踪。

</div>

---

## 这些场景你眼熟吗？

只要有一条说中了你，sitter 就是为你准备的。

- 你让 AI 去做的任务早就停了，你几小时后才发现
- 你发出了一个提问，回复一直没来，而你连自己在等回复这件事都忘了
- 一个跑通宵的任务看起来一切正常，到早上却一步都没动过
- 同时在跑的东西太多，根本分不清哪些还活着

原因永远是同一个：**没有人在盯着**。
sitter 把这份工作完全接了过来。

有一点要先说清楚：sitter 守的是**你在终端里运行的任务**。如果你只用 ChatGPT 或 Claude 的应用，那它帮不上你。

---

<a id="what"></a>

## sitter 为你做什么

四件事，按这个顺序。

```mermaid
flowchart LR
    A["1. 交给它<br/>把你的任务托付给 sitter"] --> B["2. 盯着<br/>卡住的那一刻就察觉"]
    B --> C["3. 记录<br/>把一切都写进同一个本子"]
    C --> D["4. 告诉你<br/>只在要紧的时候来找你"]
```

- 👀 **盯着**

  它一直陪着任务，不断检查它是完成了，还是在半路上冻住了。

- 📝 **记录**

  发生的一切 —— 开始了、失败了、成功了 —— 都会写进同一个本子。那只是一个纯文本文件，你随时可以回头查看当时发生了什么。

- 🔔 **告诉你**

  当发生了人类应该知道的事情，它会用你选定的方式联系你。默认是往一个备忘文件里追加一行；如果你更想收到 Slack 消息或桌面提醒，跟它说一声就行。

- ⏰ **追讨回复**

  它防止你向别人提了个问题，然后转头就忘了这回事。期限一过它会自动提醒你，最后还会说“这件事需要人类来处理了”。

---

<a id="requirements"></a>

## 你需要什么

不用买任何新东西。只要这三样。

- **一台电脑**

  Mac、Linux 或 Windows（WSL）。你日常用的机器就行。

- **从终端运行的任务**

  sitter 守的是你从终端启动的任务。Claude Code、Codex CLI 这类 AI 代理，还有测试、构建、数据处理 —— **凡是能用一条命令启动的**都算数。如果你只用 ChatGPT 或 Claude 的应用，那它帮不上你。

- **依赖和费用**

  都没有。不需要安装额外的软件，也不需要注册账号。（被看守的工具本身 —— 比如 Claude Code —— 要付多少钱，那是另一回事。）

完整对照表见[支持的环境](docs/engineering.md#compatibility)（英文）。

---

<a id="start"></a>

## 快速开始

有两条入门路径。如果你用的是**在终端里运行的 AI 代理**（Claude Code、Codex CLI 之类），直接让它来装是最快的。

> **注意：** 这里说的 Claude Code 是在终端里运行的开发者工具，不是 Claude 应用。如果你只有应用，请直接跳到下面的“自己动手安装”。

### 让你的 AI 来安装

把这个页面的网址交给你的 AI 代理，然后对它说：

```text
https://github.com/caty-ai/sitter
请用 npm install -g @caty-ai/sitter 安装这个工具，然后教我怎么用
（如果没有 npm，就按 README 里的手动安装步骤来）
```

把具体命令写进去，是为了不让代理自己发明安装路线：装进来的只有一个带来源证明（provenance）发布的官方 npm 包，用 `npm update -g @caty-ai/sitter` 就能保持最新。如果行不通，就自己照着下面的步骤做。

### 自己动手安装

三步。先打开终端 —— 在 Mac 上，它位于“应用程序 → 实用工具 → 终端”。在 Windows 上，请先阅读 [Windows 支持](docs/engineering.md#windows-support)（英文）。逐条复制命令、粘贴、按回车。

sitter 里面只有一个可读的文本脚本。它从不要你的管理员密码，也从不改动你的系统设置。

**捷径（如果你装有 Node.js）**

```sh
npm install -g @caty-ai/sitter
```

如果这条命令顺利结束，直接跳到第 2 步。装进来的是同一个脚本，用 `npm update -g @caty-ai/sitter` 即可保持最新。没有 `npm`？用下面的三步。

**1. 下载它**

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/caty-ai/sitter/main/sitter -o ~/.local/bin/sitter
chmod +x ~/.local/bin/sitter
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc    # zsh — macOS 的默认 shell
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc   # bash — Linux 和 WSL2 的默认 shell
```

最后三行让你可以直接输入 `sitter` 来调用这个工具：`export` 行对当前打开的终端生效，两条 `echo` 行让它对以后的每个终端都生效 —— 一条给 zsh（Mac 的默认），一条给 bash（Linux 和 WSL2 的默认）。两条都粘贴没有任何坏处；不属于你所用 shell 的那条只是永远不会被读取。

**2. 确认它能用**

```sh
sitter run --ledger /tmp/sitter-test.jsonl --on-fail 'cat >&2' -- sh -c 'sleep 3; echo test'
grep -o '"status":"success"' /tmp/sitter-test.jsonl
```

等大约三秒；如果出现 `"status":"success"`，就说明装好了。它的意思是“任务被看守了，完成情况已记录”。

一件容易让人意外的事：sitter 会把被看守任务的屏幕输出收进 `~/.sitter/logs/`，而不是显示在你的终端里。所以安静是正常的。想看内容的话，用 `ls ~/.sitter/logs/` 列出文件，再用 `cat ~/.sitter/logs/<文件名>` 打开其中一个。

**3. 让它看守你自己的任务**

```sh
sitter run --ledger ~/.sitter/runs.jsonl --on-fail 'cat >> ~/sitter-alerts.txt' -- sh -c 'sleep 30; echo done'
```

把 `--` 后面的内容换成**你平时输入的那条命令**。之后只要那份工作失败或卡住，就会有一条记录追加到 `~/sitter-alerts.txt`。发生了什么的完整记录留在 `~/.sitter/runs.jsonl` 里。（两者都是机器可读的格式，所以每一行看起来像一长串字符。）

这个例子只会**往文件里写** —— 屏幕上不会弹出任何东西。如果你想改成桌面通知或 Slack 消息，只需要改 `--on-fail` 运行的内容。不知道怎么做的话，就问你的 AI 代理：“给我一个能在 macOS 通知中心里弹出来的 sitter 通知”；在 Linux 和 WSL2 上则问“用 `notify-send` 发 sitter 通知”（在没有 Linux 桌面的 WSL2 上，改为请它做一个 Windows toast 通知，例如通过 PowerShell 的 BurntToast）。

**弄清什么算“卡住”**

当任务**整整 15 分钟没有任何输出 —— 屏幕上没有，日志里也没有**时，sitter 就判定它卡住了，并会停掉这个任务（硬上限是四小时）。如果你看守的工作是那种在完成前一直保持安静的类型，告诉 sitter 只用时间上限就好。这些结果在台账字段和 hook 值中的确切含义由 [ledger reason contract](docs/reference.md#ledger-reason-contract-run-family) 定义。

```sh
sitter run --ledger ~/.sitter/runs.jsonl --on-fail 'cat >> ~/sitter-alerts.txt' --stall-after 0 --timeout 3600 -- sh -c 'sleep 30; echo done'
```

<details>
<summary>如果出了问题</summary>

<br>

**提示 `sitter: command not found`**

第 1 步的最后三行可能没有生效。运行下面这一行，然后再试一次。

```sh
export PATH="$HOME/.local/bin:$PATH"
```

如果还是不行，关掉终端再重新打开。

**下载时提示 `404`**

刚发布新版本时，可能需要一点时间才能同步到各处。稍等片刻再运行一次。

</details>

---

<a id="safety"></a>

## 为什么用起来安全

“绝不擅自行动”是 sitter 设计上的顶梁柱。

- **它从不擅自重试**

  失败的任务只有在你明确声明过它可以安全重试时才会被重跑。其余情况一律只报告，不重跑。

- **有一道防止手滑的护栏**

  会发布出去或会产生费用的命令 —— `git push`、`npm publish`、`kubectl delete` 之类 —— 在被看守之前就会被拒绝。但请务必清楚它的定位：它只是**一道防止意外的简单护栏**，并不是能挡住一切危险操作的铜墙铁壁（比如 `rm` 就不在防护范围内）。

- **一切都留有记录**

  无论发生了什么，你随时都能在那个本子里查到。

- **一行命令停掉一切**

  这一行就能停掉所有的看守和重试。

  ```sh
  touch ~/.sitter/STOP
  ```

---

<a id="more"></a>

## 了解更多

按目的给出入口。

| 你想要 | 看这里 |
| --- | --- |
| 工作原理、命令、设计（面向工程师） | [docs/engineering.md](docs/engineering.md)（英文） |
| 精确的契约（每个标志、每条内部规则） | [docs/reference.md](docs/reference.md)（英文） |
| 设计是怎么一步步定下来的 | [docs/design-history.md](docs/design-history.md)（英文） |
| 我想参与贡献 | [CONTRIBUTING.md](CONTRIBUTING.md) |
| 我发现了 bug 或漏洞 | [SECURITY.md](SECURITY.md) |

<!-- family:generated:family-footer:start -->

---

本仓库属于 **Caty AI 家族** — 用于运营 AI 智能体家族的开源工具集。完整地图（包括仍在准备公开的模块）见 [Family OS](https://github.com/caty-ai/family-os)。

| 轴 | 模块 | 做什么 | 状态 |
| --- | --- | --- | --- |
| 地图 | [Family OS](https://github.com/caty-ai/family-os) | 整个家族的地图 — 模块、状态与结构 | 已公开・MIT |
| 规则 | [Family Dev Handbook](https://github.com/caty-ai/family-dev-handbook) | 开发的交通规则 — Issue、PR、worktree、交接与并行开发 | 已公开・MIT |
| 纵轴・基座 | [Caty Agent Harness](https://github.com/caty-ai/caty-agent-harness) | AI 智能体的任务基座 — 重试、检查点与完成判定 | 已公开・MIT |
| 纵轴 | [context-kit](https://github.com/caty-ai/context-kit) | 面向单个智能体的六件上下文卫生工具组 — 限制大输出、委托简报校验、安全防护、记忆检索、worktree 快照 | 已公开・MIT |
| 纵轴 | [Persona Engine](https://github.com/caty-ai/persona-engine) | 在智能体已有人格之上叠加关系与情感层 | 已公开・MIT |
| 纵轴 | [Persona Growth Loop](https://github.com/caty-ai/persona-growth-loop) | 让人格本身成长 — 以最小且幂等的提案 | 已公开・MIT |
| 纵轴 | [X Collector](https://github.com/caty-ai/x-collector) | 把 X 与网络素材汇成每日一份摘要 — 给人也给智能体 | 已公开・MIT |
| 纵轴 | [Self Growth Loop](https://github.com/caty-ai/self-growth-loop) | 让智能体自我成长的循环 — 提案、治理与采用记录 | 已公开・MIT |
| 横轴・基座 | [Family Memory Architecture](https://github.com/caty-ai/family-memory-architecture) | 记忆总线 — 家族共享所知的一层 | 已公开・MIT |
| 横轴 | **Sitter** | 替你盯着委派出去的智能体 — 监视、留证、仅在声明范围内重启 | 已公开・MIT |
| 横轴 | [Alpha Nightshift](https://github.com/caty-ai/alpha-nightshift) | 夜间自主维护循环 — 在默认拒绝的防护边界内运行夜间通道，早晨由人工挑选合并 | 已公开・MIT |

<!-- family:generated:family-footer:end -->

---

## 项目状态

[![CI](https://github.com/caty-ai/sitter/actions/workflows/ci.yml/badge.svg)](https://github.com/caty-ai/sitter/actions/workflows/ci.yml)

- **CI** — 上面的徽章是实时的：每次向 main push 以及每个 pull request 都会运行完整的 fault-injection suite，而用例数由 `make test` 自动报告
- **已验证环境** — Ubuntu 为每个 pull request 设置门禁；macOS 在每次向 main push 时运行；Windows（Git Bash）属于尽力支持
- **成熟度** — v0.3.1；4 个 v0 操作（`run` / `expect` / `ack` / `sweep`）已在 `docs/requirements-v0.md` 中作为规范冻结，而 `ask` / `watch` 则由 `docs/specs/prd-v0.2-ask-watch.md` 固定（已在 v0.2.0 中审计）
- **已知限制** — denylist 只是防止误操作的护栏，不是安全屏障；只有你明确声明为幂等的任务才会触发重试

---

## 许可证

[MIT](LICENSE) © 2026 Sho Jikumaru

我们希望任何人都能使用它、修改它，并把它构建进自己的工具和服务里，所以选了 MIT。只要保留版权声明，其余一概不限制 —— 包括商用，也包括修改后的副本。

---

<div align="center">

**一个 bash 文件** ｜ **任意 CLI 代理** ｜ **零依赖，免费**

</div>
