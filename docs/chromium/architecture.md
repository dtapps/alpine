# 仓库架构

> 本仓库同时维护两个镜像：Alpine 基础镜像（`.cnb/docker/Dockerfile.alpine`）与 Chromium 镜像（`.cnb/docker/Dockerfile.chromium` + `-headless` 变体）。本篇只讲 Chromium 这一条链路：事件触发 → buildx 多架构构建 → 推制品库 → 写 commit 元数据 → README 徽章展示，各段独立、只靠提交和制品库耦合。Alpine 基础镜像的文档在[上一级目录](../alpine/index.md)。

## 全貌

```text
触发层
  web_trigger（按钮）      crontab（每天 01:30）      tag_push        push / pull_request
         │                        │                      │                    │
         ▼                        ▼                      ▼                    ▼
流水线层（.cnb.yml include）
  build-chromium.yml       .cnb.yml main          codewiki.yml       sca.yml / code-review.yml
  （含 PR 校验 validate-chromium）  （build-alpine.yml 是另一条：Alpine 基础镜像）   knowledge-base.yml / ...
         │
         ▼
构建层（build-chromium.sh，被 source 执行）
  镜像内容：alpine:${ALPINE_VERSION} + STEP 2 显式 6 个包（其余 9 个由 chromium 的 so: 依赖自带）
  docker login → buildx 自检 → 一次多架构 buildx build --push × 3 个变体
    ├─ default（Dockerfile）        → manifest list：latest / <version>（amd64 + arm64）
    ├─ -cjk（WITH_CJK=1）           → latest-cjk / <version>-cjk
    └─ -headless（Dockerfile.headless，基于同批次 default 的 digest）
                                    → latest-headless / <version>-headless
  再对每个变体 × 每个架构：imagetools create 取子清单 digest 打单平台标签，不重建
         │
         ▼
产物层
  docker.cnb.cool/dtapp/alpine/chromium（制品库子路径，多架构标签 + 单平台标签并存；
  同仓库另一条流水线产出的 Alpine 基础镜像在 docker.cnb.cool/dtapp/alpine）
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

这种切分让改一处只影响一处：换 Alpine 版本改 `version` 输入或 Dockerfile 的 `ALPINE_VERSION` ARG 默认值（默认 `latest`，跟随上游；注意这里是 Alpine 版本，不是 Chromium 版本），不改流水线；加一条扫描流水线不改构建脚本。

构建层产出的镜像内容由 Dockerfile 这几步决定：换源（`main` + `community` 各留镜像站与官方两组 URL）→ 一次 `apk add` 显式装 6 个包（`chromium`、`ca-certificates`、`font-freefont`、`fontconfig`、`tzdata`、`tini`）→ 时区（`/etc/localtime` + `/etc/timezone`）→ 字体缓存（`fc-cache -f`）→ 清理。只写 6 个是因为 `chromium` 的 `so:` 依赖会把 `glib`、`pango`、`gdk-pixbuf`、`gtk+3.0`、`nss`、`freetype`、`harfbuzz`、`libstdc++`、`fontconfig` 这 9 个自动带进来——它们不是「被删掉的依赖」，显式写出来不增体积、删掉也不减体积。闭包实测口径（Alpine 3.24）：**184 个包 / 761 MiB installed / 约 303 MiB 下载**。包清单与取舍见 [Dockerfile 解析](dockerfile.md)。

## 触发矩阵

| 事件                           | 来源                  | 做什么                                                                                                                              | 配置                                                             |
|--------------------------------|-----------------------|-------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------|
| `web_trigger_build_chromium`   | 页面按钮              | 多架构构建、推送、冒烟、派生单平台标签、写元数据                                                                                    | `web_trigger.yml` → `build-chromium.yml`                         |
| `crontab: 30 1 * * *`          | 定时（Asia/Shanghai） | 同上，`version` 固定 `latest`                                                                                                       | `.cnb.yml` 的 `main`                                             |
| `web_trigger_build_alpine`     | 页面按钮              | 另一条流水线：Alpine 基础镜像（`build-alpine.yml`，`crontab: 5 0 * * *`）                                                           | `web_trigger.yml` → `build-alpine.yml`                           |
| `tag_push`                     | `git push --tags`     | 生成 Code Wiki 并入库知识库                                                                                                         | `codewiki.yml`                                                   |
| `web_trigger_codewiki`         | 页面按钮              | 同 Code Wiki，手动入口                                                                                                              | `web_trigger.yml` → `codewiki.yml`                               |
| `push`                         | 分支推送              | SCA 全量扫描、知识库构建                                                                                                            | `sca.yml`、`knowledge-base.yml`                                  |
| `pull_request`                 | PR                    | 校验构建：`--load` 构建 amd64 单平台、**不推送**、跑三次冒烟（`chromium --version`、`--dump-dom about:blank`、`date +%Z` 为 `CST`） | `build-chromium.yml` 的 `validate-chromium`                      |
| `pull_request`                 | PR                    | AI 评审、安全统计、扫描配置校验                                                                                                     | `code-review.yml`、`cnb-sechook.yml`、`code-security-config.yml` |
| `pull_request.target`          | PR 指向目标分支       | SCA 增量扫描并按 `failOnSeverity: high` 门禁                                                                                        | `sca.yml`                                                        |
| `issue.open` / `issue.comment` | Issue                 | 知识库同步                                                                                                                          | `knowledge-base.yml`                                             |

手动按钮共三个：「打包 Alpine 镜像（多架构 amd64 + arm64）」「打包 Chromium 镜像（多架构 amd64 + arm64）」与「生成 Code Wiki」，都要求 owner / master / developer 角色。

## 仓库文件职责

| 路径                                      | 作用                                                              |
|-------------------------------------------|-------------------------------------------------------------------|
| `.cnb.yml`                                | 流水线入口：`include` 各 workflow，定义定时任务                   |
| `.cnb/workflows/build-alpine.yml`         | 另一条流水线：Alpine 基础镜像（与本篇无关）                       |
| `.cnb/workflows/build-chromium.yml`       | Chromium 镜像的构建流水线（按钮 + PR 校验）                       |
| `.cnb/workflows/sca.yml`                  | 漏洞 / License / SBOM 扫描                                        |
| `.cnb/workflows/code-review.yml`          | PR 上的 AI 代码评审                                               |
| `.cnb/workflows/cnb-sechook.yml`          | PR 上汇总扫描与敏感信息统计                                       |
| `.cnb/workflows/code-security-config.yml` | 校验安全扫描配置本身是否合法                                      |
| `.cnb/workflows/codewiki.yml`             | Code Wiki 生成（tag 与按钮两条入口）                              |
| `.cnb/workflows/knowledge-base.yml`       | 知识库构建与 Issue 同步                                           |
| `.cnb/scripts/build-alpine.sh`            | Alpine 基础镜像的构建逻辑（与本篇无关）                           |
| `.cnb/scripts/build-chromium.sh`          | Chromium 镜像构建、推送、元数据汇总的实际逻辑                     |
| `.cnb/docker/Dockerfile.alpine`           | Alpine 基础镜像定义（与本篇无关）                                 |
| `.cnb/docker/Dockerfile.chromium`         | Chromium 镜像定义（Alpine + Chromium 运行依赖，中性基座）         |
| `.cnb/docker/Dockerfile.headless`         | `-headless` 变体：叠一层默认启动参数 + `tini` 当 PID 1            |
| `.cnb/web_trigger.yml`                    | 自定义按钮、权限、输入项                                          |
| `.cnb/settings.yml`                       | 仓库界面资源（issue 按钮图、reaction 动图）                       |
| `.cnb/security/code_scan_config.yml`      | 安全扫描配置，`ignoreFrom` 指向 `.scanignore`                     |
| `.scanignore`                             | 扫描排除清单（gitignore 语义），两个镜像共用                      |
| `Makefile`                                | `make format` 及四个子目标（一次覆盖两个镜像的脚本与 Dockerfile） |
| `.yamlfmt`                                | YAML 格式化规则                                                   |
| `docs/`                                   | Alpine 基础镜像的分册文档                                         |
| `docs/chromium/`                          | 本目录：Chromium 镜像的分册文档                                   |

Dockerfile 放在 `.cnb/docker/` 而不是根目录，是为了让 `.cnb/` 自成一体地承载「流水线 + 镜像定义」；本地构建时用 `-f .cnb/docker/Dockerfile.chromium` 显式指定，构建上下文仍是仓库根目录。变体用两种方式落地：`-cjk` 走 `--build-arg WITH_CJK=1` 复用同一份 Dockerfile，`-headless` 走独立文件 `.cnb/docker/Dockerfile.headless`（它 `FROM` 的正是同批次 default 镜像的 digest）。

## 构建链路拆解

一次流水线跑一遍 `build-chromium.sh`，只做**一次多架构构建 × 三个变体**，单平台标签不再重新构建：

1. **default 变体**：`--platform linux/amd64,linux/arm64 --push`，由 buildx 直接产出多架构 manifest list，标签 `latest`（手动填版本时再加 `<version>`）。不需要「先分别构建、再等待合并」的第三条流水线，也就不存在合并任务与竞态。
2. **`-cjk` 变体**：同一份 `.cnb/docker/Dockerfile.chromium` 加 `--build-arg WITH_CJK=1`（多装 `font-noto-cjk`），产出 `latest-cjk` / `<version>-cjk`。
3. **`-headless` 变体**：走独立的 `.cnb/docker/Dockerfile.headless`，`BASE_IMAGE` 固定为**同批次 default 镜像的 digest**（脚本现场用 `imagetools inspect` 取，取不到才退回按 tag），产出 `latest-headless` / `<version>-headless`。三个变体因此内容同源，而不是各构建各的。
4. **冒烟**：对 amd64 的 `latest` 跑三条断言（`chromium --version`、`--dump-dom about:blank`、`date +%Z` 为 `CST`），失败即退出，不再往下派生单平台标签、不写元数据。
5. **单平台标签**：对每个变体 × 每个架构，用 `docker buildx imagetools create` 从已推送的 manifest list 里取出该架构子清单的 digest，直接给 `latest[-cjk|-headless]-linux-{amd64,arm64}` 与 `<version>…` 打标签。这一步只改标签指向，**不再把同样的内容重建两遍**——旧做法连跑三次全量构建，既慢，又只能靠缓存「撞」出一致性。

所以单平台标签现在直接指向该架构的镜像清单，不再是「带 attestation 的 index」；这也是发布构建统一带 `--provenance=false --sbom=false` 的原因（buildx 版本不支持这两个参数时脚本自动跳过）。

三个变体的构建共用 `--build-arg ALPINE_VERSION=${INTERIOR_VERSION}`、同一个 `CACHE_BUST`（按天变化，见下）与同一份 registry 缓存前缀（`buildcache[-cjk|-headless]`）。镜像内容是同一套：Alpine 基础系统 + `chromium` 与它的图形/渲染依赖 + 时区数据，体积在数百 MB 量级（比纯 alpine 大一个数量级），这是 Chromium 依赖带来的预期结果，不是漏清缓存。

`ALPINE_VERSION` 只决定用哪个 Alpine 版本，**具体 Chromium 版本由该 Alpine 版本的软件包仓库决定**，构建脚本没有也不该有「指定 Chromium 版本」的参数。

### 基础版本为什么必须钉分支

`ALPINE_VERSION` 的默认值是 `latest`（`FROM alpine:${ALPINE_VERSION}`），跟随上游最新稳定版；也可钉具体补丁版本（如 `3.24.3`）做复现。需要知道的是 `chromium` 在 **community** 仓库，而 Alpine 的 community 只维护到「下一个 stable 发布」，之后每个分支里的 chromium 就冻住了：

| 分支 | chromium | 最后更新 | 分支支持到                              |
|------|----------|----------|-----------------------------------------|
| 3.20 | 131      | 2024-12  | 2026-04（**已 EOL**）                   |
| 3.21 | 136      | 2025-05  | 2026-11                                 |
| 3.22 | 142      | 2025-11  | 2027-05                                 |
| 3.23 | 149      | 2026-06  | 2027-11                                 |
| 3.24 | 155      | 2026-10  | 2028-06（唯一 main + community 双支持） |

长期停在老分支等于把浏览器 CVE 锁死，只能等换分支才修得掉。配套的 `EXPECTED_CHROMIUM_MAJOR`（默认 `155`）在装包层断言 `chromium --version` 的主版本：上游在同一分支里升主版本时，构建会**显式失败**并打印实际版本与两个处置方式——确认渲染冒烟通过后更新 Dockerfile 默认值，或传 `--build-arg EXPECTED_CHROMIUM_MAJOR=any` 跳过断言。定时任务某天变红，通常就是上游换主版本了。

### 装包层的缓存与补丁

装包层前面有一行 `echo "cache-bust: ${CACHE_BUST}"`，`CACHE_BUST` 在 CI 里是 `date -u +%Y%m%d`。这样按天击穿该层缓存：跨轮次 registry 缓存命中时 `apk add` 本来不会重跑，上游补丁就永远进不了镜像。改 Dockerfile 其它部分不会连带重装 chromium，因为击穿点只在这一层之前。

PR 上的 `validate-chromium` 走另一条更轻的路：`--load` 构建 amd64 单平台、不推送，随后三次冒烟（`chromium --version`、`--dump-dom about:blank`、`date +%Z` 为 `CST`）。它**不传 `ALPINE_VERSION` / `WITH_*`**，验证的就是 Dockerfile 里的默认值本身，免得 PR 改了默认值却仍按旧值校验。它证明「这份 Dockerfile 能构建、浏览器能起来」，避免改坏了要等次日定时任务才发现。

构建完成后脚本用 `docker buildx imagetools inspect` 取 manifest digest 与各平台镜像清单里的层体积，写成 `.cnb/annotation.json`，交由 `cnbcool/annotations` 插件写入 commit 元数据。细节见[构建元数据](metadata-and-badges.md)。

## 产物与提交的映射

- 每个成功构建把 `chromium_image_digest`、`chromium_image_digest_short`、`chromium_image_size`、`chromium_image_size_arm64`、`chromium_version`、`chromium_built_at` 写到**当前 commit** 的元数据上。
- 因此「某个提交对应哪个镜像」可以反查：Commit 列表 → 元数据，或 `https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/{key}`。
- 重跑同一提交会覆盖同名 key，只保留最后一次构建的结果；需要长期固定某个产物时，应按 digest 拉取。
- 标签会移动（`latest` 每天 `01:30` 更新一次），digest 不会；这是下游选择「标签还是 digest」的根本区别。需要固定 Chromium 版本时更是只能按 digest——版本标签固定的是 Alpine 版本。

## 关键设计取舍

| 取舍                               | 选择                                        | 理由                                                                                                                                                                                                                                      |
|------------------------------------|---------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 多架构构建用一条流水线还是三条     | 一条                                        | 免去合并 manifest 的时序问题，标签内容天然一致                                                                                                                                                                                            |
| 是否保留单平台标签                 | 保留                                        | 让调用方按标签固定平台，不必自己处理多平台条目                                                                                                                                                                                            |
| 定时任务是否也打版本标签           | 否，只打 `latest`                           | 版本标签应由人工决定，避免定时任务误覆盖历史版本                                                                                                                                                                                          |
| 元数据挂在 tag 还是 commit         | commit                                      | 本仓库不发版、不打 tag，只能靠 commit 关联产物                                                                                                                                                                                            |
| Dockerfile 放根目录还是 `.cnb/`    | `.cnb/docker/`                              | 与流水线配置放在一起，构建时用 `-f` 指定                                                                                                                                                                                                  |
| 变体用构建参数还是把参数写进主镜像 | `WITH_*` 构建参数 + 独立变体文件            | 主镜像保持中性：默认启动参数取决于使用方环境（是否 root、`/dev/shm` 多大），写进主镜像等于替所有下游决定启动方式。`-cjk` 只加一个参数复用同一份 Dockerfile，`-headless` 需要换 `ENTRYPOINT`/`CMD`，所以单独一个文件，二者都基于同批次产物 |
| 是否给 Chromium 加主版本断言       | 加（`EXPECTED_CHROMIUM_MAJOR`）             | 上游在同一分支里升主版本时必须有人知道：断言让构建显式失败并打印实际版本，处置是更新默认值或传 `any` 跳过；否则就是「镜像内容悄悄变了」                                                                                                   |
| 装包层是否按天击穿缓存             | 是（`CACHE_BUST` = 当天日期）               | 不击穿就会永远命中 registry 缓存，`apk add` 不重跑，上游补丁永远进不来                                                                                                                                                                    |
| `apk add` 显式列哪些包             | 只列闭包外的 6 个                           | 其余 9 个由 chromium 的 `so:` 依赖自动带入，显式声明不增体积、删掉也不减体积；闭包 184 个包 / 761 MiB installed，可剥离内容几乎为零（`chromium-lang` / `chromium-dbg` 本来就没装）                                                        |
| 是否预装排障工具（curl 等）        | 不装                                        | 定位是浏览器基础镜像，需要排障请基于本镜像派生                                                                                                                                                                                            |
| 无头启动参数是否写进主镜像         | 不写                                        | `--no-sandbox` 取决于使用方是否 root，应由调用方决定；要开箱即用就选 `-headless` 变体                                                                                                                                                     |
| 容器内是否预置非 root 用户         | 预置 `chrome`（UID/GID 10001），不切 `USER` | 下游写一行 `USER chrome` 就能用，不必自己在派生镜像里建用户；但默认仍是 root + `--no-sandbox`——无头 Chromium 的常见组合，切 `USER` 属于改变既有行为                                                                                       |

## 延伸阅读

- 每个事件的具体配置与插件参数：[CI 流水线](ci-pipeline.md)
- 标签命名与下游兼容性：[镜像与标签](images-and-tags.md)
- 元数据与徽章：[构建元数据](metadata-and-badges.md)
- 安全面与扫描：[安全基线](security-baseline.md)

## 相关文档

- [文档索引](README.md)
- [CI 流水线](ci-pipeline.md)
- [构建](build.md)
- [README](../../README.md)
