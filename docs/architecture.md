# 仓库架构

> 一个 Dockerfile 加一组 CNB 流水线：事件触发 → buildx 多架构构建 → 推制品库 → 写 commit 元数据 → README 徽章展示，四条链路各自独立、只靠提交和制品库耦合。

## 全貌

```text
触发层
  web_trigger（按钮）      crontab（每天 00:05）      tag_push        push / pull_request
         │                        │                      │                    │
         ▼                        ▼                      ▼                    ▼
流水线层（.cnb.yml include）
  build-image.yml          .cnb.yml main          codewiki.yml       sca.yml / code-review.yml
                                                                     knowledge-base.yml / ...
         │
         ▼
构建层（build-image.sh，被 source 执行）
  docker login → buildx 自检 → 3 次 buildx build --push
    ├─ linux/amd64,linux/arm64 → manifest list：latest / <version>
    ├─ linux/amd64             → latest-linux-amd64 / <version>-linux-amd64
    └─ linux/arm64             → latest-linux-arm64 / <version>-linux-arm64
         │
         ▼
产物层
  docker.cnb.cool/dtapp/alpine（制品库，两类标签并存）
         │
         ▼
元数据层
  .cnb/annotation.json → cnbcool/annotations → 当前 commit 元数据 → README 徽章
```

## 三层职责

| 层     | 负责                                               | 不负责                   |
|--------|----------------------------------------------------|--------------------------|
| 触发层 | 决定「什么时候构建」：按钮、定时、tag、push、PR    | 构建细节、标签命名       |
| 构建层 | 决定「构建出什么」：基础版本、源、包、标签、元数据 | 何时触发、权限、按钮展示 |
| 产物层 | 存储与分发镜像与元数据                             | 内容正确性、漏洞修复     |

这种切分让改一处只影响一处：换 Alpine 版本改 `version` 输入或 Dockerfile ARG，不改流水线；加一条扫描流水线不改构建脚本。

## 触发矩阵

| 事件                           | 来源                  | 做什么                                       | 配置                                                                        |
|--------------------------------|-----------------------|----------------------------------------------|-----------------------------------------------------------------------------|
| `web_trigger_build_image`      | 页面按钮              | 多架构构建、推送、写元数据                   | `web_trigger.yml` → `build-image.yml`                                       |
| `crontab: 5 0 * * *`           | 定时（Asia/Shanghai） | 同上，`version` 固定 `latest`                | `.cnb.yml` 的 `main`                                                        |
| `tag_push`                     | `git push --tags`     | 生成 Code Wiki 并入库知识库                  | `codewiki.yml`                                                              |
| `web_trigger_codewiki`         | 页面按钮              | 同 Code Wiki，手动入口                       | `web_trigger.yml` → `codewiki.yml`                                          |
| `push`                         | 分支推送              | SCA 全量扫描、知识库构建                     | `sca.yml`、`knowledge-base.yml`                                             |
| `pull_request`                 | PR                    | AI 评审、安全统计、扫描配置校验、SCA 增量    | `code-review.yml`、`cnb-sechook.yml`、`code-security-config.yml`、`sca.yml` |
| `pull_request.target`          | PR 指向目标分支       | SCA 增量扫描并按 `failOnSeverity: high` 门禁 | `sca.yml`                                                                   |
| `issue.open` / `issue.comment` | Issue                 | 知识库同步                                   | `knowledge-base.yml`                                                        |

手动按钮共两个：「打包 Docker 镜像（多架构 amd64 + arm64）」与「生成 Code Wiki」，都要求 owner / master / developer 角色。

## 仓库文件职责

| 路径                                      | 作用                                            |
|-------------------------------------------|-------------------------------------------------|
| `.cnb.yml`                                | 流水线入口：`include` 各 workflow，定义定时任务 |
| `.cnb/workflows/build-image.yml`          | 按钮触发的构建流水线                            |
| `.cnb/workflows/sca.yml`                  | 漏洞 / License / SBOM 扫描                      |
| `.cnb/workflows/code-review.yml`          | PR 上的 AI 代码评审                             |
| `.cnb/workflows/cnb-sechook.yml`          | PR 上汇总扫描与敏感信息统计                     |
| `.cnb/workflows/code-security-config.yml` | 校验安全扫描配置本身是否合法                    |
| `.cnb/workflows/codewiki.yml`             | Code Wiki 生成（tag 与按钮两条入口）            |
| `.cnb/workflows/knowledge-base.yml`       | 知识库构建与 Issue 同步                         |
| `.cnb/scripts/build-image.sh`             | 构建、推送、元数据汇总的实际逻辑                |
| `.cnb/docker/Dockerfile`                  | 镜像定义                                        |
| `.cnb/web_trigger.yml`                    | 自定义按钮、权限、输入项                        |
| `.cnb/settings.yml`                       | 仓库界面资源（issue 按钮图、reaction 动图）     |
| `.cnb/security/code_scan_config.yml`      | 安全扫描配置，`ignoreFrom` 指向 `.scanignore`   |
| `.scanignore`                             | 扫描排除清单（gitignore 语义）                  |
| `Makefile`                                | `make format` 及四个子目标                      |
| `.yamlfmt`                                | YAML 格式化规则                                 |
| `docs/`                                   | 本目录：分册文档                                |

Dockerfile 放在 `.cnb/docker/` 而不是根目录，是为了让 `.cnb/` 自成一体地承载「流水线 + 镜像定义」；本地构建时用 `-f .cnb/docker/Dockerfile` 显式指定，构建上下文仍是仓库根目录。

## 构建链路拆解

一次构建包含三次 `docker buildx build --push`，顺序固定：

1. **多架构 manifest list**：`--platform linux/amd64,linux/arm64`，产出 `latest`（手动填版本时再加 `<version>`）。这一步直接由 buildx 生成 index，不需要「先分别构建、再等待合并」的第三条流水线，也就不存在合并任务与竞态。
2. **amd64 单平台**：`--platform linux/amd64`，产出 `latest-linux-amd64`（及版本变体）。
3. **arm64 单平台**：`--platform linux/arm64`，产出 `latest-linux-arm64`（及版本变体）。

第 2、3 步与第 1 步共用同一个 builder 的 BuildKit 层缓存，命中缓存后主要开销在推层。三次构建都带 `--build-arg ALPINE_VERSION=${INTERIOR_VERSION}`，保证同一批标签内容一致。

构建完成后脚本用 `docker buildx imagetools inspect` 取 manifest digest 与各平台镜像清单里的层体积，写成 `.cnb/annotation.json`，交由 `cnbcool/annotations` 插件写入 commit 元数据。细节见[构建元数据](metadata-and-badges.md)。

## 产物与提交的映射

- 每个成功构建把 `image_digest`、`image_digest_short`、`image_size`、`image_size_arm64`、`built_at` 写到**当前 commit** 的元数据上。
- 因此「某个提交对应哪个镜像」可以反查：Commit 列表 → 元数据，或 `https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/{key}`。
- 重跑同一提交会覆盖同名 key，只保留最后一次构建的结果；需要长期固定某个产物时，应按 digest 拉取。
- 标签会移动（`latest` 每天更新），digest 不会；这是下游选择「标签还是 digest」的根本区别。

## 关键设计取舍

| 取舍                            | 选择              | 理由                                             |
|---------------------------------|-------------------|--------------------------------------------------|
| 多架构构建用一条流水线还是三条  | 一条              | 免去合并 manifest 的时序问题，标签内容天然一致   |
| 是否保留单平台标签              | 保留              | 让调用方按标签固定平台，不必自己处理多平台条目   |
| 定时任务是否也打版本标签        | 否，只打 `latest` | 版本标签应由人工决定，避免定时任务误覆盖历史版本 |
| 元数据挂在 tag 还是 commit      | commit            | 本仓库不发版、不打 tag，只能靠 commit 关联产物   |
| Dockerfile 放根目录还是 `.cnb/` | `.cnb/docker/`    | 与流水线配置放在一起，构建时用 `-f` 指定         |
| 容器内是否创建非 root 用户      | 否                | 定位是基础调试镜像，生产环境应自行加 `USER`      |

## 延伸阅读

- 每个事件的具体配置与插件参数：[CI 流水线](ci-pipeline.md)
- 标签命名与下游兼容性：[镜像与标签](images-and-tags.md)
- 元数据与徽章：[构建元数据](metadata-and-badges.md)
- 安全面与扫描：[安全基线](security-baseline.md)

## 相关文档

- [文档索引](README.md)
- [CI 流水线](ci-pipeline.md)
- [构建](build.md)
- [README](../README.md)
