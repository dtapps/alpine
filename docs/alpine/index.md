# 文档索引

> `docker.cnb.cool/dtapp/alpine` 这个自建 Alpine 基础镜像的完整说明：镜像里有什么、是怎么构建出来的、标签怎么用、流水线怎么触发、出问题怎么查。

本目录的 [README](README.md) 是 Alpine 镜像的一页速查，这里把里面点到为止的部分展开成可操作的分册。两者冲突时以代码为准（见「事实来源」），并顺手修掉过时的那一份。

> 本目录只讲 **Alpine 基础镜像**（`docker.cnb.cool/dtapp/alpine`）。 同仓库的 Chromium 镜像（`docker.cnb.cool/dtapp/alpine/chromium`）文档在 [../chromium/](../chromium/README.md)，两套镜像共用根目录的 CONTRIBUTING 与 SECURITY。

## 从哪里开始

| 你的目的                         | 先读                                  | 再读                                         |
|----------------------------------|---------------------------------------|----------------------------------------------|
| 第一次用这个镜像                 | [快速上手](getting-started.md)        | [镜像与标签](images-and-tags.md)             |
| 想改镜像内容（加包、换源、时区） | [Dockerfile 解析](dockerfile.md)      | [APK 源与网络](mirrors.md)、[构建](build.md) |
| 想改流水线或触发方式             | [CI 流水线](ci-pipeline.md)           | [构建元数据](metadata-and-badges.md)         |
| 想知道某次提交对应哪个镜像       | [构建元数据](metadata-and-badges.md)  | [镜像与标签](images-and-tags.md)             |
| 要升级 Alpine 版本或做日常维护   | [维护手册](maintenance.md)            | [CI 流水线](ci-pipeline.md)                  |
| 构建/拉取/徽章出问题了           | [排错手册](troubleshooting.md)        | [构建](build.md)                             |
| 想参与贡献                       | [CONTRIBUTING](../../CONTRIBUTING.md) | [格式化](formatting.md)                      |

## 文档清单

| 文档                                             | 内容                                                        | 对应实现                                        |
|--------------------------------------------------|-------------------------------------------------------------|-------------------------------------------------|
| [architecture.md](architecture.md)               | 仓库全貌、触发矩阵、文件职责、关键设计取舍                  | `.cnb.yml`、`.cnb/workflows/**`                 |
| [getting-started.md](getting-started.md)         | 拉取、运行、容器内自检、作为基础镜像、按 digest 固定        | 制品库 + `Dockerfile`                           |
| [dockerfile.md](dockerfile.md)                   | Dockerfile 逐段解析、加包标准、层与体积                     | `.cnb/docker/Dockerfile.alpine`                 |
| [mirrors.md](mirrors.md)                         | APK 源顺序、版本号推导、源失效处置、供应链信任面            | `Dockerfile` 里写源那段                         |
| [build.md](build.md)                             | 本地与 CI 构建、buildx、多架构产物落地方式                  | `.cnb/scripts/build-alpine.sh`                  |
| [ci-pipeline.md](ci-pipeline.md)                 | 事件矩阵、按钮与权限、imports、插件职责、改流水线步骤       | `.cnb.yml`、`.cnb/web_trigger.yml`、`workflows` |
| [images-and-tags.md](images-and-tags.md)         | 镜像地址、标签契约、manifest list 与单平台镜像、digest 固定 | 制品库 + 构建脚本                               |
| [metadata-and-badges.md](metadata-and-badges.md) | 元数据十键、写入链路、徽章、体积统计原理                    | `build-alpine.sh`、`cnbcool/annotations`        |
| [security-baseline.md](security-baseline.md)     | 镜像攻击面、扫描能力、`.scanignore` 原则、凭证管理          | `.scanignore`、`.cnb/security/**`、`sca.yml`    |
| [maintenance.md](maintenance.md)                 | 补丁节奏、版本升级、验证清单、周期性检查                    | `crontab`、`web_trigger_build_alpine`           |
| [troubleshooting.md](troubleshooting.md)         | 症状到处置的总表与分主题排查                                | 全仓库                                          |
| [formatting.md](formatting.md)                   | `make format` 四目标、各格式化器配置、编辑器集成            | `Makefile`、`.yamlfmt`                          |

## 与仓库根目录文档的分工

| 文件                                     | 定位                                                   |
|------------------------------------------|--------------------------------------------------------|
| [README.md](README.md)                   | 一页速查：镜像有什么、怎么拉、怎么触发构建、怎么格式化 |
| [CONTRIBUTING.md](../../CONTRIBUTING.md) | 贡献流程、硬性规则、PR 检查清单                        |
| [SECURITY.md](../../SECURITY.md)         | 支持范围、漏洞报告渠道、已知取舍                       |
| 本目录（`docs/alpine/`）                 | 展开版：机制说明 + 完整操作步骤，按主题分册            |

本目录不重复根文档的结论。需要引用时用相对链接，避免同一件事写两遍后逐渐不一致。

## 事实来源

文档的事实基准只有这几个文件，改动行为时先改代码、再改文档：

| 文件                            | 决定什么                               |
|---------------------------------|----------------------------------------|
| `.cnb/docker/Dockerfile.alpine` | 镜像内容：基础版本、源、包、时区、清理 |
| `.cnb/scripts/build-alpine.sh`  | 构建、推送、标签拼接、元数据汇总       |
| `.cnb.yml`、`.cnb/workflows/**` | 什么事件触发什么流水线                 |
| `.cnb/web_trigger.yml`          | 按钮名称、权限、输入项                 |
| `Makefile`、`.yamlfmt`          | 格式化范围与规则                       |

## 维护约定

- 行为变更必须同步文档：改镜像 → [dockerfile.md](dockerfile.md) 与 [getting-started.md](getting-started.md)；改流水线 → [ci-pipeline.md](ci-pipeline.md)；改标签 → [images-and-tags.md](images-and-tags.md)；改元数据键 → [metadata-and-badges.md](metadata-and-badges.md)；改扫描配置 → [security-baseline.md](security-baseline.md)；改格式化 → [formatting.md](formatting.md)。
- 提交前跑 `make format-markdown`，让表格与空行符合 `markdownfmt` 的结果。
- 链接一律用相对路径：本目录内互链写 `xxx.md`，指向仓库根目录写 `../../xxx.md`，指向 Chromium 文档写 `../chromium/xxx.md`。
- 新增文档要补进上面的「文档清单」表格，否则等于不存在。

## 相关文档

- [README](README.md)
- [CONTRIBUTING](../../CONTRIBUTING.md)
- [SECURITY](../../SECURITY.md)
