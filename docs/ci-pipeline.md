# CI 流水线

> `.cnb.yml` 只负责 `include` 与定时任务，每个事件的具体步骤分散在 `.cnb/workflows/*.yml`；这里讲清这套组织方式、事件与 workflow 的逐条对应、以及改动流水线时必须同步的位置。

## 为什么拆成 include

一条流水线要同时承载构建、扫描、评审、文档生成、知识库同步五类互不相关的事情。全塞进 `.cnb.yml` 会得到一份几百行、谁都不敢动的文件，所以按「一个事件一组职责」拆成 7 个文件，`.cnb.yml` 只保留两件事：`include` 列表和 `main` 上的定时任务。改 SCA 阈值不会碰到构建脚本，改构建不会误删评审配置。

代价是触发关系不再集中在一处：某个事件到底跑哪些步骤，需要跨文件看。下表就是用来补这个信息。

## 配置的三层结构

```yaml
include:
  - .cnb/workflows/build-image.yml
  # ... 共 7 个文件

main:
  'crontab: 5 0 * * *':
    - name: build-image
      stages:
        - name: 构建并推送多架构镜像
          script: |
            source .cnb/scripts/build-image.sh
```

两层键决定「什么时候跑」：

- 顶层键是分支过滤器。`.cnb.yml` 里定时任务挂在 `main` 下，只对默认分支生效；7 个 workflow 文件统一用 `'**'`，对所有分支生效。
- 事件名在过滤器下一层，值是流水线数组。`push`、`pull_request`、`tag_push`、`issue.open`、`web_trigger_build_image` 都是同级事件键；定时事件把 cron 表达式写进键名并加引号（`'crontab: 5 0 * * *'`），因为键值里有空格和 `*`。

## 事件与 workflow 对应表

| 事件                           | 定义位置                                                                   | 产物                                                                                                                           |
|--------------------------------|----------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| `web_trigger_build_image`      | `workflows/build-image.yml`                                                | 解析基座版本 → 一次 `buildx build --push` 推版本标签 → 派生单平台标签 → 冒烟 → 提升 `latest`/`<minor>`；`.cnb/annotation.json` |
| `'crontab: 5 0 * * *'`         | `.cnb.yml` 的 `main`                                                       | 同上；不传 `version`，走 `Dockerfile` 默认的 `alpine:latest`（每天跟上游），标签用解析出的实际版本                             |
| `tag_push`                     | `workflows/codewiki.yml`                                                   | `${CNB_BUILD_WORKSPACE}/${CNB_REPO_SLUG}/codewiki` 下的 Code Wiki                                                              |
| `web_trigger_codewiki`         | `workflows/codewiki.yml`                                                   | 同上                                                                                                                           |
| `push`                         | `workflows/sca.yml`、`workflows/knowledge-base.yml`                        | SCA 全量报告附件、知识库索引                                                                                                   |
| `pull_request`                 | `workflows/code-review.yml`、`cnb-sechook.yml`、`code-security-config.yml` | PR 评论、扫描与敏感信息统计、配置校验结果                                                                                      |
| `pull_request.target`          | `workflows/sca.yml`                                                        | 增量扫描，`failOnSeverity: high` 时门禁失败                                                                                    |
| `issue.open` / `issue.comment` | `workflows/knowledge-base.yml`                                             | 知识库同步                                                                                                                     |

`push` 在两个文件里各声明一次，一次 push 会同时拉起 SCA 全量扫描与知识库构建，两段互不依赖；`tag_push` 与 `web_trigger_codewiki` 在 `codewiki.yml` 里是两份内容相同的流水线，改生成参数必须同步两处。

## imports 与 source

构建相关的两段流水线（手动按钮、定时任务）使用同一组 `imports`：

```yaml
imports:
  - https://cnb.cool/dtapp/envs/-/blob/main/docker.yml
  - .cnb/scripts/build-image.sh
```

第一项来自组织 `envs` 仓库，提供构建所需的环境变量；凭证只以 `${CNB_TOKEN}`、`${CNB_TOKEN_USER_NAME}` 的形式出现在脚本里，真实值不进本仓库（见 [CONTRIBUTING](../CONTRIBUTING.md)）。第二项声明脚本依赖，脚本本身也在仓库内。

这一项引用的是 `main` 分支而不是固定 commit：上游改了 `docker.yml`，本仓库下一次构建就会跟着变。这是组织统一 管理环境变量的代价，属于已知取舍（见 [SECURITY](../SECURITY.md)）。脚本因此不依赖其中任何「可选」变量：缺变量时 用 `:?` 展开立即失败，而不是带着空值静默降级。

真正执行发生在 stages 里，且必须用 `source`：

```bash
source .cnb/scripts/build-image.sh   # 正确：变量与输出留在当前 shell
sh .cnb/scripts/build-image.sh       # 错误：set-output 与 export 都随子进程消失
```

原因写在脚本头部：它要 `printf '##[set-output interior_version=%s\n' "${ALPINE_REAL}"` 把解析出的基座版本交给 CNB 采集，再 `export INTERIOR_VERSION`/`IMAGE_VERSION` 给同一步里的后续命令用。换成 `sh` 执行，这两件事都发生在子进程里，外层拿不到。

## runner tags 与 docker 服务

```yaml
runner:
  tags: cnb:arch:amd64
services:
  - docker
```

`tags` 是调度条件：任务只会落到带 `cnb:arch:amd64` 标签的 Runner。arm64 产物也在这台 amd64 Runner 上产出，靠 CNB `services: docker` 内置的多架构 buildx 完成跨架构构建，所以不需要单独找 arm64 机器。

`services: docker` 同时提供 docker daemon 与现成的 builder。脚本里的 `docker buildx version` 与 `docker buildx inspect` 两条自检就是确认这一点（`docker buildx ls` 留在需要人工看 builder 列表时用）。 不要在脚本里 `docker buildx create --driver docker-container`：受限容器拉不起嵌套 buildkitd，会以 bootstrap 失败告终。

## stages 与 set-output

一次 stage 一个 `name`，两种形态：

- `script:` 内联 shell，构建步骤用它；
- `image:` 指定容器镜像加 `settings:`，插件步骤用它。

`##[set-output key=value]` 是 CNB 的 stage 输出语法，写出的值进入 stage 结果，供后续步骤和流水线界面读取。脚本输出两个 key：`interior_version`（等于解析出的基座版本，如 `3.25.1`，保留旧字段兼容）与 `image_version`（等于本次版本标签名，如 `3.25.1`）。同时用同名大写的环境变量给后续命令用，两者职责不同，不要混用。

## 构建链路：从 version 到元数据

脚本从头到尾只有一次真正的构建，其余都是解析、引用改写与验证。下面按执行顺序列出全部 12 段（编号即脚本里的注释段）：

```text
0.  环境变量自检                 CNB_DOCKER_REGISTRY / CNB_REPO_SLUG_LOWERCASE / CNB_TOKEN* 缺一即失败（:? 展开）
1.  version 白名单校验           空|latest → 跟随 Dockerfile；也可 3.25 / 3.25.1 / 3.25.1@sha256:<64hex>
2.  基座引用                     version 入参，或 Dockerfile 的 ARG ALPINE_VERSION（默认 latest）
3.  解析基座版本与 digest         一次性容器读 /etc/alpine-release → ALPINE_REAL；imagetools 取 BASE_DIGEST
4.  时间戳与标签                 STAMP=${ALPINE_REAL}（标签就是 alpine 版本号，不带日期）；MINOR=major.minor
5.  登录                         docker login --password-stdin；trap 在退出时删掉 ~/.docker/config.json
6.  buildx 自检                  version / inspect 两条确认内置 builder 可用
7.  一次多架构构建               --platform linux/amd64,linux/arm64 --push，只打 -t ${IMAGE}:${STAMP}
                                 build-arg：ALPINE_VERSION / IMAGE_VERSION=${STAMP} / VCS_REF / BUILD_DATE / BASE_DIGEST
8.  imagetools create            派生 ${STAMP}-linux-amd64 / -linux-arm64，digest 与 index 条目相同
9.  冒烟测试                     pull 后 amd64 起容器跑六项断言（含基座版本前缀、OCI 标签 version）
10. 提升                         先 create -t ${MINOR}，再 create -t latest，都指向 ${STAMP}
11. 元数据                       取 index digest 与各平台层体积，加两个时间戳与 base_digest，写 .cnb/annotation.json
```

第 3 段是这套设计的关键：`latest` 只用于 `FROM`，**标签里永远不会出现 `latest`**，写进标签的是读出来的 `/etc/alpine-release`（如 `3.25.1`）。解析失败会直接 `exit 1`，不会带着「不知道是什么版本」的基座继续构建。

`set -eu` 从第一行生效，所以任何一步失败都会立刻中止；这是「冒烟失败不会顺带提升 `latest`」的前提。

两个时间戳分工不同：`BUILD_DATE` 取最后一次提交时间（`git log -1 --format=%cI`，取不到回落 `1970-01-01T00:00:00Z`），作为 `--build-arg` 进镜像、落成 OCI `created` 标签；`base.digest` 也跟着 `--build-arg BASE_DIGEST` 进镜像。所以「同一份源码 + 同一个基座 digest」重复构建的 config 才是逐字节一致的，基座一旦前移，`created` 之外的 `base.digest` 也会变；本次运行的真实时刻（`date -u +%Y-%m-%dT%H:%M:%SZ`）只写进元数据的 `built_at`，不进镜像。 把运行时刻也算成提交时间，等于为了可复现丢掉「这次构建是什么时候跑的」这条信息。

标签不带日期：`3.25.1` 这种名字每天被同名覆盖，`3.25` 与 `latest` 在冒烟通过后被提升。所以「这一份具体是什么时候构建的」只能从元数据的 `built_at` 读，而不是从标签名读；想留住某一份产物，只能记下当次的 `image_digest`。

提升顺序是「minor 在前、latest 最后」：`3.25` 那次提升失败时，`latest` 一定还指向上一份可用产物，不会出现「minor 没更新但 latest 已经动了」的中间态。

### 为什么不启用 registry 缓存

一个反直觉的取舍：buildx 支持把构建缓存推到制品库（`--cache-from`/`--cache-to type=registry`），让下一个 job 直接命中，这里却**刻意不用**。

原因是这份镜像只有一个 `RUN`：缓存能复用的就是那一层，一旦命中，`apk add` 整段都不会再执行——索引不刷新、 包不重新解析。于是每日 00:05 的定时构建会永远装到启动缓存那天的包，`v3.25` 仓库里后来发布的包级安全补丁一个也进不来，而这恰恰是定时重建存在的全部理由。

省下来的成本很小：不带缓存时每次多跑的是「4 个索引 + 5 个包」的下载与解包，实测秒级；可复用的层本来也只有 一层，谈不上多少命中收益。所以这里的选择是：

| 取舍     | 带 registry 缓存           | 不带缓存（当前选择）                   |
|----------|----------------------------|----------------------------------------|
| 构建耗时 | 命中后只推一层，最快       | 每次多几秒索引与装包                   |
| 依赖刷新 | 命中即冻结，包级补丁进不来 | 每次重建都重新解析索引，装到当时最新   |
| 可复现性 | 同 digest 更容易复现       | 靠 `image_digest` + `base_digest` 回查 |

「镜像只有一个 RUN」这个前提一旦变了（多阶段构建、拆出独立的装包层），缓存的价值就会回来，那时应当重新评估， 而不是照抄现在的结论。

### 为什么显式写 --provenance=mode=min --sbom=false

buildx 默认会给推送的 index 追加 attestation 清单：provenance（默认 `mode=min`，记录构建参数与来源）以及 SBOM（默认开启，记录完整包清单）。这些条目会让 `imagetools inspect` 的输出多出额外清单、让「按平台求层体积」 必须额外过滤，统计口径也跟着漂。这里把两个开关写成显式值：保留最小的来源证明，关掉 SBOM，使 index 的形状只由 「两个平台镜像清单」决定；buildx 将来改默认值也不会悄悄改变统计口径。需要完整 SBOM 时应当走 SCA 的 `cnbcool/sca-sbom`，那里产出的是可归档的报告，不是镜像里的附加清单。

### 为什么冒烟要在提升之前

`latest` 与 `3.25` 是会立刻被下游消费的移动标签，版本标签（如 `3.25.1`）则在构建阶段就推上去了。把断言卡在提升之前，最坏情况是「版本标签暂时指向一份坏产物、按 `latest`/`3.25` 拉的人不受影响」，而不是「下游拿到一个时区错了/源没换的镜像」。六项断言刻意选的都是本仓库自己改得坏的地方，以及「解析出的版本与实际基座是否一致」：

| 断言                                          | 防的是什么                                                 |
|-----------------------------------------------|------------------------------------------------------------|
| `/etc/alpine-release` 前缀为 `${ALPINE_REAL}` | 解析出的版本与真正拉到的基座不一致（缓存、代理、tag 漂移） |
| `cat /etc/timezone` 为 `Asia/Shanghai`        | 时区文件没落盘，或 `tzdata` 被误删                         |
| `date +%z` 为 `+0800`                         | 只写了 `/etc/timezone`（给程序看）却漏了 `/etc/localtime`  |
| `/etc/apk/repositories` 4 行                  | 换源脚本写错行数，或误把 `community` 打开                  |
| `curl`/`drill`/`nc`/`nslookup` 可执行         | 包名写错（例如 `bind-tools` 与 `drill` 混用）后构建仍成功  |
| OCI 标签 `version` 等于 `${STAMP}`            | `--build-arg IMAGE_VERSION` 没传对，元数据与产物对不上     |

### 为什么构建上下文要先排除

`.dockerignore` 把 `.git`（约 1.8 MB）、`docs/`、`*.md`、`LICENSE`、`Makefile` 与工具配置全部排除， 构建上下文从 3.0 MB 降到约 0.1 MB。镜像里只用得上 `.cnb/docker/Dockerfile`，其余都是每次构建都要重新 打包上传的传输噪声；上下文越小，构建开始得越快，也越不容易把本地未提交的杂物带进镜像。

## 插件职责

| 插件镜像                           | 出现位置                             | 职责与关键参数                                                                 |
|------------------------------------|--------------------------------------|--------------------------------------------------------------------------------|
| `cnbcool/annotations:latest`       | `build-image.yml`、`.cnb.yml` `main` | `type: ADD` + `fromJsonFile: .cnb/annotation.json`，写 commit 元数据           |
| `cnbcool/codewiki:latest`          | `codewiki.yml`                       | 生成 Code Wiki，`git_doc_dir` 指定落盘目录，`timeout: 3h`                      |
| `cnbcool/knowledge-base`           | `knowledge-base.yml`                 | `include: '**/**.md'`、`issueSyncEnabled: true`、`ignoreProcessFailures: true` |
| `cnbcool/sca-vulnerability:latest` | `sca.yml`                            | 组件漏洞扫描，`scanMode: full/diff`、`publish: true`、`failOnSeverity: high`   |
| `cnbcool/sca-license:latest`       | `sca.yml`                            | License 扫描，参数同上                                                         |
| `cnbcool/sca-sbom:latest`          | `sca.yml`                            | SBOM，`format: spdx`                                                           |
| `cnbcool/code-review:latest`       | `code-review.yml`                    | PR 上的 AI 评审，`comment`、`min_severity`、`exclude_categories`、`model` 等   |
| `cnbcool/cnb-sechook`              | `cnb-sechook.yml`                    | 汇总扫描结果与敏感信息统计，`max_display_authors: 5`                           |
| `cnbcool/code-security-config`     | `code-security-config.yml`           | `args: [validate]`，校验扫描配置本身合法                                       |

插件镜像多数只有 `:latest`（`cnbcool/annotations` 目前没有版本化 tag，构建网络内也取不到它的 digest）， 所以插件升级不被本仓库控制。这是已知的供应链薄弱点，写在 [SECURITY](../SECURITY.md) 的已知取舍里； 脚本侧的对策是「元数据 key 结构固定 + 冒烟核对 OCI 标签」，插件行为一变，下一次构建就能看出来。

扫描策略与忽略规则见[安全基线](security-baseline.md)，插件参数排错见[故障排查](troubleshooting.md)。

## web_trigger.yml：按钮与权限

按钮定义在 `branch.buttons` 下，字段固定为 `name`、`description`、`event`、`permissions.roles`，可选 `inputs`：

| 按钮                                     | event                     | 权限                       | 输入                                                                       |
|------------------------------------------|---------------------------|----------------------------|----------------------------------------------------------------------------|
| 打包 Docker 镜像（多架构 amd64 + arm64） | `web_trigger_build_image` | owner / master / developer | `version`，`required: false`，`default: ''`（留空 = 跟随 `alpine:latest`） |
| 生成 Code Wiki                           | `web_trigger_codewiki`    | owner / master / developer | 无                                                                         |

`version` 留空与填 `latest` 等价，都表示「跟随上游最新稳定版」；也可以填 `3.25`（跟随该分支补丁）、`3.25.1`（钉死 patch）或 `3.25.1@sha256:<64 位 hex>`（位级复现）。其它值会被脚本白名单拒绝，所以在按钮上写错不会跑出一半才失败。

`event` 与 workflow 文件里的事件键是同一个字符串：两边字面量不一致，按钮点下去就不会产生流水线。`inputs` 里的 key 直接变成脚本读到的小写变量 `version`。

## 新增或修改流水线

1. 改 `.cnb/workflows/` 下的文件，根键 `'**'`，事件名下一层放流水线数组；
2. 新增文件必须加进 `.cnb.yml` 的 `include`，忘记就等于没写；改已有文件不需要动 `include`；
3. 需要手动入口时在 `.cnb/web_trigger.yml` 加按钮，`event` 与 workflow 事件键逐字一致，权限只给需要的角色；
4. 改事件名要同时改 `web_trigger.yml`、`include` 引用与文档，改 inputs 要同时改脚本里读变量的地方；
5. 推送逻辑改动落在 `.cnb/scripts/build-image.sh`，失败必须显式 `exit 1`；提交前跑 `make format`。

## 典型失败与排查入口

| 症状                      | 常见原因                                                                                 | 先看哪里                       |
|---------------------------|------------------------------------------------------------------------------------------|--------------------------------|
| 点按钮没有任何流水线产生  | `web_trigger.yml` 的 `event` 与 workflow 事件键不一致，或该 workflow 不在 `include` 里   | 按钮定义、`include` 列表       |
| 脚本报 version 非法       | 输入不是 latest / `3.25` / `3.25.1` / `3.25.1@sha256:<64hex> 之一（如 `v3.25`、`3.25/`） | 白名单校验的报错输出           |
| 解析不到基座版本          | 一次性容器拉不到 `alpine:latest`，或 `/etc/alpine-release` 读不到                        | 第 3 段的「无法解析」报错      |
| `FROM` 阶段拉不到基础镜像 | `version` 不是 Docker Hub 上真实存在的 alpine tag                                        | 构建步骤日志、`version` 输入值 |
| 冒烟失败、`latest` 没更新 | 基座版本前缀不符、时区、源行数、命令缺失或 OCI 标签 `version` 不符                       | 冒烟步骤的断言输出             |
| buildx bootstrap 失败     | 脚本里自建了 docker-container builder                                                    | 脚本的 buildx 自检段输出       |
| 徽章显示 `unknown`        | 元数据解析失败（体积记 `-1`）或 digest 未取到                                            | 日志里的「体积解析失败」行     |
| 定时任务不生效            | 定时任务只在 `main` 顶层键下声明，改在其它分支上不会生效                                 | `.cnb.yml`、默认分支内容       |

排查入口：

```text
流水线运行记录   https://cnb.cool/dtapp/alpine/-/pipeline
定时任务状态     https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/status/crontab
本次流水线配置   https://cnb.cool/dtapp/alpine/-/blob/main/.cnb.yml
commit 元数据    https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/image_digest
```

## 相关文档

- [仓库架构](architecture.md)
- [镜像与标签](images-and-tags.md)
- [构建元数据与徽章](metadata-and-badges.md)
- [安全基线](security-baseline.md)
