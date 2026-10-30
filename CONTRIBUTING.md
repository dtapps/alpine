# 贡献指南

本仓库只做一件事：用一份 `Dockerfile` 构建自建 Alpine 基础镜像，并由 CNB 流水线推送到制品库。它没有应用代码、没有测试用例，所以「贡献」通常意味着改 `Dockerfile`、改流水线脚本，或修文档。

安全问题的报告渠道在 [SECURITY.md](SECURITY.md)，不要用 issue 报敏感问题。

## 环境准备

- Docker（需要 `buildx`）
- 格式化工具：`yamlfmt`、`markdownfmt`、`shfmt`、`dockerfmt`

```bash
brew install shfmt yamlfmt markdownfmt dockerfmt
# 或 go install mvdan.cc/sh/v3/cmd/shfmt@latest 等对应模块
```

## 可以改什么

| 路径                            | 作用                                 | 注意                                    |
|---------------------------------|--------------------------------------|-----------------------------------------|
| `.cnb/docker/Dockerfile`        | 镜像定义：APK 源、包列表、时区、清理 | 见下方「加包的标准」                    |
| `.cnb/scripts/build-image.sh`   | 构建、推送、元数据汇总               | 命令失败要显式 `exit 1`，不要吞错误     |
| `.cnb/workflows/*.yml`          | 各事件对应的流水线                   | 改事件名必须同步 `.cnb/web_trigger.yml` |
| `.cnb.yml`                      | include 列表与定时任务               | 见 README「触发构建」                   |
| `.cnb/security/`、`.scanignore` | 安全扫描配置                         | 只在确认误报时加排除                    |
| `README.md`                     | 使用文档                             | 行为变了就同步                          |
| `docs/`                         | 分册文档（索引 `docs/README.md`）    | 行为变了同步对应分册，并补进索引表格    |

## 提交前必做

1. 跑 `make format`。YAML / Markdown / Shell / Dockerfile 四类统一格式化，CI 不校验格式，但 diff 里混进格式噪音会拖慢评审。
2. 本地构建一次，确认镜像仍可用：

```bash
docker build -f .cnb/docker/Dockerfile --build-arg ALPINE_VERSION=latest -t alpine:local .
docker run --rm alpine:local sh -c 'command -v curl nc dig nslookup; date'
```

3. 改了推送逻辑的话，先用自己 fork 的路径试推，别拿 `docker.cnb.cool/dtapp/alpine` 做实验性推送。

## 硬性规则

- **不提交任何凭证**。脚本只允许通过 `${CNB_TOKEN}` / `${CNB_TOKEN_USER_NAME}` 取值，真实凭证在组织密钥仓库（`imports`）。写死 token 会被敏感信息扫描拦下，但别指望扫描兜底。
- **不加不必要的包**。这个镜像的卖点是体积：新增包要在 PR 里说明「解决什么场景」「大约增加多少体积」。能用 `--no-cache` 的不留缓存。
- **清理步骤留在最后一层**。`/var/cache/apk`、`/tmp`、`/root/.cache` 的清理一旦被新加 `RUN` 挤到前面，中间层就会把体积带进镜像。
- **APK 源顺序有意义**。cernet → 腾讯云 → 阿里云 → 火山 → 官方，是「国内可用性 + 兜底」的顺序，调整要说明理由。
- **Shell 风格固定**：`shfmt -i 2 -ci -bn -s -ln bash`，两空格缩进；脚本是被 `source` 执行的，不要在里面的命令上加 `set -x`，也不要把 token 打进日志。
- **标签命名是对外契约**。`latest`、`<version>`、`latest-linux-{arch}` 这套命名已有下游在用，改名前先在 issue 里讨论。
- **`.scanignore` 排除面保持最小**。每加一条都要写明为什么它是噪音。

## 分支与提交信息

- 分支：`feat/xxx`、`fix/xxx`，对 `main` 提 PR。
- 提交信息用 Conventional Commits + 中文描述，与现有历史保持一致：

```text
feat(dockerfile): 增加 jq 便于脚本里解析 JSON
fix(script): 修正 arm64 体积统计取到 index 的问题
docs: 补充元数据徽章的读取方式
```

## PR 检查清单

- [ ] `make format` 已跑，没有格式 diff
- [ ] 本地单架构构建通过，容器内 `date` 显示 `Asia/Shanghai`
- [ ] 新增包在 PR 描述里写清用途与体积代价
- [ ] 行为变更已同步到 `README.md`，以及 `docs/` 下对应的分册
- [ ] 没有新增凭证，没有放宽 `.scanignore`
