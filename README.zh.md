# sitter

<div align="center">

[🇺🇸 English](README.md) ｜ [🇯🇵 日本語](README.ja.md) ｜ **🇨🇳 简体中文** ｜ [🇹🇭 ไทย](README.th.md)

![Sitter 品牌主视觉图：“SITTER”、“A WATCH POST FOR DELEGATED AI WORK”、“caty-ai/sitter” 与 “FREE & OPEN SOURCE · MIT LICENSE” 字样，旁边是一个复古电视机风格的行星生态系统。一座珊瑚橙色的小型外围观测哨在不拥有目标运行时的前提下守望着被委派的工作；图片本身不代表任何依赖关系。](assets/readme/hero.png)

<h4>一个免费工具，替你守着那些交给 AI 或电脑去跑的长时间任务。</h4>

[![CI](https://github.com/caty-ai/sitter/actions/workflows/ci.yml/badge.svg)](https://github.com/caty-ai/sitter/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![bash](https://img.shields.io/badge/runtime-bash%203.2%2B-4EAA25?logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(WSL)-lightgrey)
![deps](https://img.shields.io/badge/dependencies-none-success)

[它是做什么的](#what) ｜ [你需要什么](#requirements) ｜ [快速开始](#start) ｜ [为什么安全](#safety) ｜ [了解更多](#more)

它会检查任务是否真的完成了、是不是悄悄停在了半路，<br>
以及你一直在等的那个回复是不是被遗忘了 —— 并且一定会告诉你。

**再也不会有任务不声不响地消失。**

🔧 [面向工程师的文档](docs/engineering.md)（英文） ｜ 📘 [详细规格](docs/reference.md)（英文）

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
请安装这个工具，并教我怎么用
```

sitter 是一个小巧的单文件工具，大多数代理会一路把它装完。如果行不通，就自己照着下面的步骤做。

### 自己动手安装

三步。先打开终端 —— 在 Mac 上，它位于“应用程序 → 实用工具 → 终端”。在 Windows 上，请先阅读 [Windows 支持](docs/engineering.md#windows-support)（英文）。逐条复制命令、粘贴、按回车。

sitter 里面只有一个可读的文本脚本。它从不要你的管理员密码，也从不改动你的系统设置。

**1. 下载它**

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/caty-ai/sitter/main/sitter -o ~/.local/bin/sitter
chmod +x ~/.local/bin/sitter
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

最后两行让你可以直接输入 `sitter` 来调用这个工具（第一行对当前打开的终端生效，第二行对以后打开的每个终端生效）。在没有 `zsh` 的 Linux 上，把 `~/.zshrc` 换成 `~/.bashrc`。

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

这个例子只会**往文件里写** —— 屏幕上不会弹出任何东西。如果你想改成桌面通知或 Slack 消息，只需要改 `--on-fail` 运行的内容。不知道怎么做的话，就问你的 AI 代理：“给我一个能在 macOS 通知中心里弹出来的 sitter 通知”。

**弄清什么算“卡住”**

当任务**整整 15 分钟没有任何输出 —— 屏幕上没有，日志里也没有**时，sitter 就判定它卡住了，并会停掉这个任务（硬上限是四小时）。如果你看守的工作是那种在完成前一直保持安静的类型，告诉 sitter 只用时间上限就好。

```sh
sitter run --ledger ~/.sitter/runs.jsonl --on-fail 'cat >> ~/sitter-alerts.txt' --stall-after 0 --timeout 3600 -- sh -c 'sleep 30; echo done'
```

<details>
<summary>如果出了问题</summary>

<br>

**提示 `sitter: command not found`**

第 1 步的最后两行可能没有生效。运行下面这一行，然后再试一次。

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

---

## 许可证

[MIT](LICENSE) © 2026 Caty

我们希望任何人都能使用它、修改它，并把它构建进自己的工具和服务里，所以选了 MIT。只要保留版权声明，其余一概不限制 —— 包括商用，也包括修改后的副本。

---

<div align="center">

**一个 bash 文件** ｜ **任意 CLI 代理** ｜ **零依赖，免费**

</div>
