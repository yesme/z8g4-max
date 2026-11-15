# CLI 会话

安装与账号模型文档见装机计划第 5 节。用自己的普通用户在目标机安装和登录，先在对应项目跑一次交互冒烟。将官方 CLI 的 bin 目录加入自己的 PATH。脚本中的 `muse` / `kimi` 按当前官方安装实际生成的可执行文件核验。tmux 会话按 CLI 和工作树路径区分。同一 CLI 同一工作树若要开两次，建议用两个 Git worktree。

先按主机安装手册创建 `/srv/work/jackywang`，再以 `jackywang` 克隆或迁入项目。`repo` 换为已存在的 Git checkout。同一仓库的 worktree 共用 Git 对象库，检出的源码、index 和各自的 `buck-out` 仍由各工作树单独管理。

```bash
kit=$(realpath /path/to/z8-kit)
repo=/srv/work/jackywang/example
git -C "$repo" worktree add -b task/codex /srv/work/jackywang/example-codex
git -C "$repo" worktree add -b task/claude /srv/work/jackywang/example-claude
bash "$kit/harness/agent-session.sh" codex /srv/work/jackywang/example-codex
# Ctrl-b d 后可继续启动另一个会话。
bash "$kit/harness/agent-session.sh" claude /srv/work/jackywang/example-claude
tmux list-sessions
```

每个 CLI 首次单独启动，先走原生登录，选模型后执行只读项目任务确认权限。需要长期保留时用 `Ctrl-b d`，重连后用同一个 CLI 和 worktree 参数接回。不同人的凭证用不同 Unix 用户及文件权限。

## ZCode 终端版

先看 [官方 release](https://github.com/zai-org/ZCode/releases) 是否提供对应 Linux CLI 分发包。若需要从源构建，按官方仓库版本和 `mise.toml` 配置 Node 与 pnpm，安装该 checkout 的 workspace 依赖，运行 `pnpm build:zcode`。按构建输出与 README 解包，先以 `node /path/to/extracted/bin/zcode.mjs --help` 验入口，再用官方分发安装方式或在自己的 `~/.local/bin` 建启动器。启动后测试 TUI 登录和 GLM 模型选择。 [官方构建与分发步骤](https://github.com/zai-org/ZCode/blob/main/README.en.md)

## OMP、Pi、DSH 直连 DeepSeek 官方 API

DeepSeek 官方 API 的模型 ID 是 `deepseek-flash`，当前服务版本是 V4.1-Flash-1017。OMP 和 Pi 用内置 `deepseek` provider。DSH 的官方 `deepseek-official` 路由用 `https://api.deepseek.com/anthropic`，出厂默认模型是 `deepseek-flash`。三者共用你已有的 `DEEPSEEK_API_KEY`。 [DeepSeek 官方模型](https://api-docs.deepseek.com/quick_start/pricing/) · [OMP 模型选择](https://upd.dev/can1357/oh-my-pi/src/branch/main/docs/models.md) · [Pi 官方 DeepSeek provider 测试](https://github.com/earendil-works/pi/blob/main/packages/ai/test/stream.test.ts) · [DSH 默认路由](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/bundle/base/cordis.patch.yml#L81) · [DSH 凭证与协议](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/llm/llm-deepseek/README.md)

用 `jackywang` 在工作站上安装。OMP 可用 Bun 安装，Pi 和 DSH 用用户态 Node/npm。用 Node 24.9 或更高，先看各包实际声明的版本约束。将用户态 bin 目录加入登录环境，验证三个命令的版本。 [OMP 安装](https://github.com/can1357/oh-my-pi#installation) · [Pi 安装](https://github.com/earendil-works/pi/tree/main/packages/coding-agent#installation) · [DSH CLI](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/cli/README.md)

```bash
# 如果还没有 Node 24 和 Bun，先以普通用户安装。已有的话从版本检查开始。
git clone --branch v0.40.3 --depth 1 https://github.com/nvm-sh/nvm.git "$HOME/.nvm"
. "$HOME/.nvm/nvm.sh"
nvm install 24
curl -fsSL https://bun.sh/install | bash
export PATH="$HOME/.bun/bin:$PATH"
node --version
bun --version
npm view @earendil-works/pi-coding-agent version engines
npm view @deepseek-ai/dsh version engines
bun install -g @oh-my-pi/pi-coding-agent
npm install -g @earendil-works/pi-coding-agent @deepseek-ai/dsh
omp --version
pi --version
dsh --version
```

在启动 CLI 的交互 SSH shell 内读入密钥。通过 `agent-session.sh` 新建 OMP、Pi 或 DSH 会话时，脚本把密钥传给该新会话，即使 tmux 服务已在运行。凭证通过环境变量交给进程，命令历史和配置样例只记录变量名。每条启动命令在各自 worktree 执行。

```bash
read -rsp 'DeepSeek API key: ' DEEPSEEK_API_KEY
printf '\n'
export DEEPSEEK_API_KEY
omp models find deepseek-flash
pi --list-models deepseek-flash
dsh --profile headless --dump-config | grep -A 5 agent-default-model
```

```bash
# 各自在对应的 worktree 里运行。
omp --model deepseek/deepseek-flash
pi --model deepseek/deepseek-flash
dsh --profile headless '读取 README.md，用两句话说明项目用途。'
```

若 DSH 已有自定义 profile 或保存了其他模型选择，先在实际 profile 查 `agent-default-model`，在新会话前确认 `provider: deepseek-official` 与 `model: deepseek-flash`。已保存的 DSH provider 凭证和自定义 endpoint 也要核对。三个 CLI 都先用合成工单验证读文件、一次工具调用和工具回传。已启动的 CLI 不会因外部 shell 重读密钥而更新，换 key 时结束该 CLI，再用新变量启动会话。 [Pi 环境变量](https://pi.dev/docs/latest/providers) · [DSH 模型设置](https://deepseek-harness.github.io/deepseek-harness/en/guide/providers)

### 本地 1017 验机入口

需要用 OMP 做本地闭环时，把 `omp-models.yml.example` 的 `z8-deepseek` 合并到 `~/.omp/agent/models.yml`，模型选择 `z8-deepseek/deepseek-v4.1-flash-1017`。默认通过 loopback 使用单槽 128K llama.cpp 服务。`contextWindow` 样例为 `131072`；I6 选定不同档位时同步填实际每槽 token 数。启用 8K Xolotl 回退时把端口改为 8150，`contextWindow` 改为 `8192`。并发和性能用本地 1017 探针及固定任务验证。
