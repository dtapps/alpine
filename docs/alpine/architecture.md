# 仓库架构

> 一个 Dockerfile 加一组 CNB 流水线：事件触发 → buildx 多架构构建 → 推制品库 → 写 commit 元数据 → README 徽章展示，四条链路各自独立、只靠提交和制品库耦合。

## 全貌

```text
触发层
  web_trigger（按钮）      crontab（每天 00:05）      tag_push        push / pull_request
         │                        │                      │                    │
         ▼                        ▼                      ▼                    ▼
流水线层（.cnb.yml include）
  build-alpine.yml          .cnb.yml main          codewiki.yml       sca.yml / code-review.yml
                                                                     knowledge-base.yml / ...
         │
         ▼
构建层（build-alpine.sh，被 source 执行）
  version 白名单校验 → 解析基座版本与 digest → docker login --password-stdin → buildx 自检
    ├─ 解析基座：一次性容器读 /etc/alpine-release → 3.25.1；imagetools 取 alpine:latest 的 digest
    ├─ 一次 buildx build --platform linux/amd64,linux/arm64 --push
    │    └─ 版本标签 3.25.1（多架构 index，同名标签每天被覆盖）
    ├─ imagetools create 派生 3.25.1-linux-{amd64,arm64}（digest 不变，同样每天覆盖）
    ├─ 冒烟测试（amd64 容器内六项断言，含基座版本前缀 + OCI 标签 version）
    └─ 冒烟通过 → imagetools create 提升 latest / 3.25；失败 → exit 1，两个移动标签不动
         │
         ▼
产物层
  docker.cnb.cool/dtapp/alpine（制品库：版本标签每天覆盖，minor / latest 前移；历史只靠 digest）
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

这种切分让改一处只影响一处：要临时换基座就改 `version` 输入，不改流水线；要长期偏离上游才动 Dockerfile 的 ARG；加一条扫描流水线不改构建脚本。

## 触发矩阵

| 事件                           | 来源                  | 做什么                                                   | 配置                                                                        |
|--------------------------------|-----------------------|----------------------------------------------------------|-----------------------------------------------------------------------------|
| `web_trigger_build_alpine`     | 页面按钮              | 一次多架构构建、派生单平台标签、冒烟后提升、写元数据     | `web_trigger.yml` → `build-alpine.yml`                                      |
| `crontab: 5 0 * * *`           | 定时（Asia/Shanghai） | 同上；不传 `version`，跟随 `alpine:latest`（每天跟上游） | `.cnb.yml` 的 `main`                                                        |
| `tag_push`                     | `git push --tags`     | 生成 Code Wiki 并入库知识库                              | `codewiki.yml`                                                              |
| `web_trigger_codewiki`         | 页面按钮              | 同 Code Wiki，手动入口                                   | `web_trigger.yml` → `codewiki.yml`                                          |
| `push`                         | 分支推送              | SCA 全量扫描、知识库构建                                 | `sca.yml`、`knowledge-base.yml`                                             |
| `pull_request`                 | PR                    | AI 评审、安全统计、扫描配置校验、SCA 增量                | `code-review.yml`、`cnb-sechook.yml`、`code-security-config.yml`、`sca.yml` |
| `pull_request.target`          | PR 指向目标分支       | SCA 增量扫描并按 `failOnSeverity: high` 门禁             | `sca.yml`                                                                   |
| `issue.open` / `issue.comment` | Issue                 | 知识库同步                                               | `knowledge-base.yml`                                                        |

手动按钮共两个：「打包 Alpine 镜像（多架构 amd64 + arm64）」与「生成 Code Wiki」，都要求 owner / master / developer 角色。

## 仓库文件职责

| 路径                                      | 作用                                            |
|-------------------------------------------|-------------------------------------------------|
| `.cnb.yml`                                | 流水线入口：`include` 各 workflow，定义定时任务 |
| `.cnb/workflows/build-alpine.yml`         | 按钮触发的构建流水线                            |
| `.cnb/workflows/sca.yml`                  | 漏洞 / License / SBOM 扫描                      |
| `.cnb/workflows/code-review.yml`          | PR 上的 AI 代码评审                             |
| `.cnb/workflows/cnb-sechook.yml`          | PR 上汇总扫描与敏感信息统计                     |
| `.cnb/workflows/code-security-config.yml` | 校验安全扫描配置本身是否合法                    |
| `.cnb/workflows/codewiki.yml`             | Code Wiki 生成（tag 与按钮两条入口）            |
| `.cnb/workflows/knowledge-base.yml`       | 知识库构建与 Issue 同步                         |
| `.cnb/scripts/build-alpine.sh`            | 构建、推送、元数据汇总的实际逻辑                |
| `.cnb/docker/Dockerfile.alpine`           | 镜像定义                                        |
| `.cnb/web_trigger.yml`                    | 自定义按钮、权限、输入项                        |
| `.cnb/settings.yml`                       | 仓库界面资源（issue 按钮图、reaction 动图）     |
| `.cnb/security/code_scan_config.yml`      | 安全扫描配置，`ignoreFrom` 指向 `.scanignore`   |
| `.scanignore`                             | 扫描排除清单（gitignore 语义）                  |
| `Makefile`                                | `make format` 及四个子目标                      |
| `.yamlfmt`                                | YAML 格式化规则                                 |
| `.dockerignore`                           | 构建上下文排除清单，把上下文压到约 0.1 MB       |
| `docs/`                                   | 本目录：分册文档                                |

Dockerfile 放在 `.cnb/docker/` 而不是根目录，是为了让 `.cnb/` 自成一体地承载「流水线 + 镜像定义」；本地构建时用 `-f .cnb/docker/Dockerfile.alpine` 显式指定，构建上下文仍是仓库根目录。

## 构建链路拆解

一次构建只有一次 `docker buildx build`，其余步骤都是解析、引用改写与验证。脚本按注释段编号执行 12 段，归并成六个阶段：

1. **校验与解析**：`version` 只接受 `空|latest|3.25|3.25.1|3.25.1@sha256:<64hex>`；再起一个一次性容器读 `/etc/alpine-release` 得到 `ALPINE_REAL`（如 `3.25.1`），并从 `imagetools` 取基座 index digest `BASE_DIGEST`。**标签里永远不出现 `latest`**。
2. **一次多架构构建**：`--platform linux/amd64,linux/arm64 --push`，只打 `-t ${IMAGE}:${STAMP}`（`STAMP=${ALPINE_REAL}`，标签不带日期）。刻意不挂 registry 缓存（理由见 CI 流水线那节），并 `--provenance=mode=min --sbom=false`，让 index 形状只由两个平台清单决定。
3. **派生单平台标签**：`docker buildx imagetools create` 把 index 里该平台条目的 digest 挂到 `${STAMP}-linux-amd64` / `-linux-arm64`。这一步不执行构建，digest 与 index 条目完全相同。
4. **冒烟测试（amd64）**：先 `docker pull` 再起容器，断言 `/etc/alpine-release` 前缀等于 `ALPINE_REAL`、`/etc/timezone`、`date +%z`、`/etc/apk/repositories` 行数、四个命令可执行，并核对 OCI 标签 `version` 等于 `${STAMP}`。
5. **提升移动标签**：冒烟通过后 `imagetools create` 把 `${MINOR}` 与 `latest` 指向 `${STAMP}`；失败则 `exit 1`，两个移动标签留在上一份可用产物上。
6. **汇总元数据**：`imagetools inspect` 取 index digest 与各平台镜像清单里的层体积，连同 `alpine_version`、`base_digest`、两个时间戳写成 `.cnb/annotation.json`，由 `cnbcool/annotations` 写入 commit 元数据。细节见[构建元数据](metadata-and-badges.md)。

第 1 阶段是这套设计的前提：基座跟随 `latest`，但**产物必须知道自己吃的是什么**。解析出 `3.25.1` 之后，标签、`alpine_version`、OCI `base.digest` 才都有确定值；否则「跟随最新」会变成「不知道在用哪个版本」。第 2 与第 3 阶段的关系则是另一半：**构建产生一个名字，其余名字都是它的别名**，省掉两次完整构建（含两次 `apk add`），也不可能出现「几个标签内容略有差异」这种最难排查的故障。

## 产物与提交的映射

- 每个成功构建把 `image_digest`、`image_digest_short`、`image_version`、`alpine_version`、`base_image`、`base_digest`、`image_size`、`image_size_arm64`、`built_at`、`source_date` 写到**当前 commit** 的元数据上（共 10 个 key）。`built_at` 是本次运行时刻，`source_date` 是提交时间（同时作为镜像的 OCI `created`），所以「什么时候跑的」靠前者，「对应哪次提交」靠后者。
- 因此「某个提交对应哪个镜像」可以反查：Commit 列表 → 元数据，或 `https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/{key}`。
- 重跑同一提交会覆盖同名 key，只保留最后一次构建的结果；需要长期固定某个产物时，只能按 `image_digest` 以 digest 形式拉取，并自行留档。
- 标签不带日期：`<版本>`（如 `3.25.1`）每天被同名覆盖，`<minor>` 与 `latest` 每次成功构建前移。所以四个标签都是「当前」的视角，没有一个是历史；历史只能靠元数据里的 `image_digest`（外加 `built_at`、`alpine_version`、`base_digest`）追溯。

## 关键设计取舍

| 取舍                            | 选择                                 | 理由                                                                      |
|---------------------------------|--------------------------------------|---------------------------------------------------------------------------|
| 多架构构建用一条流水线还是三条  | 一条                                 | 免去合并 manifest 的时序问题，标签内容天然一致                            |
| 单平台标签怎么来                | `imagetools create` 派生             | 不重建，digest 与 index 条目相同，省两次完整构建                          |
| 标签是覆盖还是留档              | 全部是当前视角的标签，不留档         | 版本标签每天覆盖、minor/latest 前移；历史交给元数据 digest，语义最直白    |
| 移动标签什么时候提升            | 冒烟测试通过之后                     | 坏产物最多落在版本标签上，按 `latest`/`<minor>` 拉的下游不受影响          |
| 定时任务是否跟随上游 `latest`   | 是，默认 `ARG ALPINE_VERSION=latest` | 用户要的就是每天自动吃上游补丁；可追溯性改由解析版本 + `base_digest` 承担 |
| 是否启用 registry 缓存          | 不启用                               | 只有一层 `RUN`，缓存命中后 `apk add` 不再执行，cron 也就装不到新包        |
| 补丁怎么进镜像                  | 每天重建自动刷新                     | 装包层不缓存、`FROM latest`，包级补丁与新 patch 最迟次日都进来            |
| 是否带完整 provenance / SBOM    | `mode=min` + `sbom=false`            | index 形状只由平台清单决定，体积统计口径稳定；SBOM 走 SCA 报告            |
| 元数据挂在 tag 还是 commit      | commit                               | 本仓库不发版、不打 tag，只能靠 commit 关联产物                            |
| Dockerfile 放根目录还是 `.cnb/` | `.cnb/docker/`                       | 与流水线配置放在一起，构建时用 `-f` 指定                                  |
| 容器内是否创建非 root 用户      | 否，并显式 `USER root`               | 定位是基础调试镜像，显式声明让取舍在 `docker history` 里可见              |
| 基座是否钉版本                  | 不钉，跟随 `latest`                  | 钉死会让补丁进不来；复现靠 `image_digest` + `base_digest`，不靠重跑       |

## 延伸阅读

- 每个事件的具体配置与插件参数：[CI 流水线](ci-pipeline.md)
- 标签命名与下游兼容性：[镜像与标签](images-and-tags.md)
- 元数据与徽章：[构建元数据](metadata-and-badges.md)
- 安全面与扫描：[安全基线](security-baseline.md)

## 相关文档

- [文档索引](index.md)
- [CI 流水线](ci-pipeline.md)
- [构建](build.md)
- [README](README.md)
