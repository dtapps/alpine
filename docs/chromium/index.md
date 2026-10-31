# 文档索引：Alpine + Chromium 无头浏览器基础镜像

> `docker.cnb.cool/dtapp/alpine/chromium` —— Alpine + Chromium 无头浏览器基础镜像的完整说明：镜像里有什么、怎么在容器里跑无头浏览器、是怎么构建出来的、标签怎么用、流水线怎么触发、出问题怎么查。

同目录的 [README.md](README.md) 是一页速查，本目录把里面点到为止的部分展开成可操作的分册。两者冲突时以代码为准（见「事实来源」），并顺手修掉过时的那一份。

> **仓库合并说明**：Chromium 镜像现在与 Alpine 基础镜像同仓库（`dtapp/alpine`）维护， 镜像地址是子路径 `docker.cnb.cool/dtapp/alpine/chromium`，并且 **Chromium 以本仓库构建的 Alpine 基础镜像为基座**（CI 按 digest 钉住，`latest` 由每天 `00:05` 的基座构建产出）。本目录文档从原独立的 `alpine-chromium` 仓库迁入，镜像地址、元数据键（`chromium_` 前缀）、脚本与流水线 文件名已同步；描述「仓库全貌」的段落（尤其 [architecture.md](architecture.md)、 [ci-pipeline.md](ci-pipeline.md)）按合并后的布局写。Alpine 基础镜像的文档在 [上一级目录](../alpine/index.md)。

## 从哪里开始

| 你的目的                         | 先读                                  | 再读                                         |
|----------------------------------|---------------------------------------|----------------------------------------------|
| 第一次用这个镜像                 | [快速上手](getting-started.md)        | [镜像与标签](images-and-tags.md)             |
| 要在容器里截图 / 导 PDF / 跑 E2E | [快速上手](getting-started.md)        | [排错手册](troubleshooting.md)               |
| 想改镜像内容（加包、换源、时区） | [Dockerfile 解析](dockerfile.md)      | [APK 源与网络](mirrors.md)、[构建](build.md) |
| 想改流水线或触发方式             | [CI 流水线](ci-pipeline.md)           | [构建元数据](metadata-and-badges.md)         |
| 想知道某次提交对应哪个镜像       | [构建元数据](metadata-and-badges.md)  | [镜像与标签](images-and-tags.md)             |
| 要升级 Alpine 版本或做日常维护   | [维护手册](maintenance.md)            | [CI 流水线](ci-pipeline.md)                  |
| 构建/拉取/徽章出问题了           | [排错手册](troubleshooting.md)        | [构建](build.md)                             |
| 想参与贡献                       | [CONTRIBUTING](../../CONTRIBUTING.md) | [格式化](formatting.md)                      |

## 文档清单

| 文档                                             | 内容                                                                 | 对应实现                                                 |
|--------------------------------------------------|----------------------------------------------------------------------|----------------------------------------------------------|
| [architecture.md](architecture.md)               | 仓库全貌、触发矩阵、文件职责、关键设计取舍                           | `.cnb.yml`、`.cnb/workflows/**`                          |
| [getting-started.md](getting-started.md)         | 拉取、无头截图与 PDF、容器内自检、作为基础镜像、按 digest 固定       | 制品库 + `Dockerfile`                                    |
| [dockerfile.md](dockerfile.md)                   | Dockerfile 逐段解析、依赖闭包与体积、字体与可选开关、加包标准        | `.cnb/docker/Dockerfile.chromium`、`Dockerfile.headless` |
| [mirrors.md](mirrors.md)                         | APK 源策略、Alpine 版本推导、源失效处置、供应链信任面                | `Dockerfile` 的换源段（仅 CNB）                          |
| [build.md](build.md)                             | 本地与 CI 构建、buildx、多架构产物落地方式                           | `.cnb/scripts/build-chromium.sh`                         |
| [ci-pipeline.md](ci-pipeline.md)                 | 事件矩阵、按钮与权限、imports、插件职责、改流水线步骤                | `.cnb.yml`、`.cnb/web_trigger.yml`、`workflows`          |
| [images-and-tags.md](images-and-tags.md)         | 镜像地址、标签契约、manifest list 与单平台标签、digest 固定          | 制品库 + 构建脚本                                        |
| [metadata-and-badges.md](metadata-and-badges.md) | 元数据键（含 `chromium_version`）、写入链路、徽章、按平台统计体积    | `build-chromium.sh`、`cnbcool/annotations`               |
| [security-baseline.md](security-baseline.md)     | 镜像攻击面（Chromium 依赖、root 运行）、扫描能力、`.scanignore` 原则 | `.scanignore`、`.cnb/security/**`、`sca.yml`             |
| [maintenance.md](maintenance.md)                 | 补丁节奏、版本升级、验证清单、周期性检查                             | `crontab`、`web_trigger_build_chromium`                  |
| [troubleshooting.md](troubleshooting.md)         | 症状到处置的总表与分主题排查（含无头启动、渲染、`/dev/shm`）         | 全仓库                                                   |
| [formatting.md](formatting.md)                   | `make format` 四目标、各格式化器配置、编辑器集成                     | `Makefile`、`.yamlfmt`                                   |

## 与根目录文档的分工

| 文件                                       | 定位                                                       |
|--------------------------------------------|------------------------------------------------------------|
| [README.md](README.md)                     | Chromium 镜像的一页速查：有什么、怎么拉、怎么触发构建      |
| [CONTRIBUTING.md](../../CONTRIBUTING.md)   | 贡献流程、硬性规则、PR 检查清单（两个镜像共用）            |
| [SECURITY.md](../../SECURITY.md)           | 支持范围、漏洞报告渠道、已知取舍（两个镜像共用）           |
| [`../alpine/index.md`](../alpine/index.md) | Alpine 基础镜像的文档索引                                  |
| 本目录                                     | Chromium 镜像的展开版：机制说明 + 完整操作步骤，按主题分册 |

`docs/` 不重复根文档的结论。需要引用时用相对链接，避免同一件事写两遍后逐渐不一致。

## 事实来源

文档的事实基准只有这几个文件，改动行为时先改代码、再改文档：

| 文件                              | 决定什么                                                 |
|-----------------------------------|----------------------------------------------------------|
| `.cnb/docker/Dockerfile.alpine`   | 基座内容：Alpine 版本、源（main-only）、工具、时区       |
| `.cnb/docker/Dockerfile.chromium` | 镜像内容：基座引用、源覆写、包、时区、环境变量、预置用户 |
| `.cnb/docker/Dockerfile.headless` | 本地派生配方：默认无头参数 + tini（CI 不发布）           |
| `.cnb/scripts/build-chromium.sh`  | 构建、推送、标签拼接、元数据汇总                         |
| `.cnb.yml`、`.cnb/workflows/**`   | 什么事件触发什么流水线                                   |
| `.cnb/web_trigger.yml`            | 按钮名称、权限、输入项                                   |
| `Makefile`、`.yamlfmt`            | 格式化范围与规则                                         |
| `.scanignore`、`.cnb/security/**` | 扫描范围与排除                                           |

## 维护约定

- 行为变更必须同步文档：改镜像 → [dockerfile.md](dockerfile.md) 与 [getting-started.md](getting-started.md)；改流水线 → [ci-pipeline.md](ci-pipeline.md)；改标签 → [images-and-tags.md](images-and-tags.md)；改元数据键 → [metadata-and-badges.md](metadata-and-badges.md)；改扫描配置 → [security-baseline.md](security-baseline.md)；改格式化 → [formatting.md](formatting.md)。
- 徽章与元数据（各 key 含义、体积怎么算、`unknown` 什么含义）只在 [metadata-and-badges.md](metadata-and-badges.md) 解释，其它篇引用而不另立说法。
- 安全取舍（root 运行、排障工具跟随基座、未签名、无层扫描）以 [SECURITY.md](../../SECURITY.md) 为准，`docs/` 只解释取舍的影响，不复述整张清单。
- 提交前跑 `make format-markdown`，让表格与空行符合 `markdownfmt` 的结果。
- 链接一律用相对路径：本目录内互链写 `xxx.md`，指向仓库根目录写 `../../xxx.md`，指向 Alpine 基础镜像文档写 `../xxx.md`。
- 新增文档要补进上面的「文档清单」表格，否则等于不存在。

## 相关文档

- [README](../../README.md)
- [CONTRIBUTING](../../CONTRIBUTING.md)
- [SECURITY](../../SECURITY.md)
