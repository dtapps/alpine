# CI 流水线

> `.cnb.yml` 只负责 `include` 与定时任务，每个事件的具体步骤分散在 `.cnb/workflows/*.yml`；这里讲清这套组织方式、事件与 workflow 的逐条对应、构建流水线的九个步骤与它的入参校验/缓存策略，以及改动流水线时必须同步的位置。

## 为什么拆成 include

一条流水线要同时承载构建、扫描、评审、文档生成、知识库同步五类互不相关的事情。全塞进 `.cnb.yml` 会得到一份几百行、谁都不敢动的文件，所以按「一个事件一组职责」拆成 8 个文件，`.cnb.yml` 只保留两件事：`include` 列表和 `main` 上的定时任务。改 SCA 阈值不会碰到构建脚本，改构建不会误删评审配置。

仓库合并后这里有两套构建流水线：`build-alpine.yml`（Alpine 基础镜像，`web_trigger_build_alpine` + `crontab: 5 0 * * *`）与 `build-chromium.yml`（本篇的 Chromium 镜像，`web_trigger_build_chromium` + `crontab: 5 1 * * *`）。二者不是并列关系：**Chromium 的基座就是 build-alpine 的产物**，构建前按 `version` 选基座标签、解析出实际 Alpine 版本，再钉 `<仓库 slug>:<实际版本>` 的 digest，取不到直接失败。两条 cron 因此必须保持先后：`00:05` 先产基座，`01:05` 再叠 Chromium（中间留 1 小时给基座构建与 latest 提升），同时也避开了两个多架构重任务同时跑。

代价是触发关系不再集中在一处：某个事件到底跑哪些步骤，需要跨文件看。下表就是用来补这个信息。

## 配置的三层结构

```yaml
include:
  - .cnb/workflows/build-alpine.yml
  - .cnb/workflows/build-chromium.yml
  # ... 共 8 个文件

main:
  'crontab: 5 0 * * *':   # Alpine 基础镜像（Chromium 的基座）
    - name: build-alpine
      stages:
        - name: 构建并推送多架构镜像
          script: |
            source .cnb/scripts/build-alpine.sh
  'crontab: 5 1 * * *':  # Chromium 镜像（基座产出后才能跑）
    - name: build-chromium
      stages:
        - name: 构建并推送多架构镜像
          script: |
            source .cnb/scripts/build-chromium.sh
```

两层键决定「什么时候跑」：

- 顶层键是分支过滤器。`.cnb.yml` 里定时任务挂在 `main` 下，只对默认分支生效；8 个 workflow 文件统一用 `'**'`，对所有分支生效。
- 事件名在过滤器下一层，值是流水线数组。`push`、`pull_request`、`tag_push`、`issue.open`、`web_trigger_build_chromium` 都是同级事件键；定时事件把 cron 表达式写进键名并加引号（`'crontab: 5 1 * * *'`），因为键值里有空格和 `*`。两条构建流水线只有 `web_trigger_*` 与定时两个入口，`push` / `pull_request` 属于本目录的其它 workflow。

## 事件与 workflow 对应表

| 事件                                                | 定义位置                                                                                       | 产物                                                                                                                                                       |
|-----------------------------------------------------|------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `web_trigger_build_chromium`                        | `workflows/build-chromium.yml`                                                                 | 解析本仓库基座实际版本与 digest → 1 次多架构 `buildx build --push` → 派生两个单平台标签 → 冒烟与基座标签校验 → 提升 minor / latest；`.cnb/annotation.json` |
| `'crontab: 5 1 * * *'`                              | `.cnb.yml` 的 `main`                                                                           | 同上，但 `version` 恒为 `latest`：产物版本标签仍是解析出的实际 Alpine 版本，只是不会切到别的基座分支                                                       |
| `web_trigger_build_alpine` / `'crontab: 5 0 * * *'` | `workflows/build-alpine.yml`、`.cnb.yml` 的 `main`                                             | 另一条流水线：Alpine 基础镜像，也是 Chromium 的基座（自身细节见 [Alpine 基础镜像文档](../alpine/index.md)）                                                |
| `tag_push`                                          | `workflows/codewiki.yml`                                                                       | `${CNB_BUILD_WORKSPACE}/${CNB_REPO_SLUG}/codewiki` 下的 Code Wiki                                                                                          |
| `web_trigger_codewiki`                              | `workflows/codewiki.yml`                                                                       | 同上                                                                                                                                                       |
| `push`                                              | `workflows/sca.yml`、`workflows/knowledge-base.yml`                                            | SCA 全量报告附件、知识库索引                                                                                                                               |
| `pull_request`                                      | `workflows/code-review.yml`、`workflows/cnb-sechook.yml`、`workflows/code-security-config.yml` | PR 评论、扫描与敏感信息统计、扫描配置校验结果                                                                                                              |
| `pull_request.target`                               | `workflows/sca.yml`                                                                            | 增量扫描，`failOnSeverity: high` 时门禁失败                                                                                                                |
| `issue.open` / `issue.comment`                      | `workflows/knowledge-base.yml`                                                                 | 知识库同步                                                                                                                                                 |

`push` 在两个文件里各声明一次，一次 push 会同时拉起 SCA 全量扫描与知识库构建，两段互不依赖；`tag_push` 与 `web_trigger_codewiki` 在 `codewiki.yml` 里是两份内容相同的流水线，改生成参数必须同步两处。`sca.yml` 不响应普通 `pull_request`，PR 上只有 `pull_request.target` 那一段（增量 + `failOnSeverity: high` 门禁）；`push` 侧的全量扫描刻意把 `failOnSeverity` 留在注释状态——上游未修的 CVE 必然出现在全量报告里，设门禁只会让每次 push 常红，失去「留一份基线」的意义，理由见[安全基线](security-baseline.md)。

`pull_request` 在表里出现多行，是同一个事件被多个文件各自声明：`code-review.yml` 等三个文件做评审与扫描，互不依赖，PR 上并行跑。构建流水线不响应 `pull_request`，PR 不会触发镜像构建。

## 构建流程

`build-chromium.sh` 用一次多架构构建产出一个中性镜像，单平台标签不再重新构建。按脚本的执行顺序：

| # | 步骤                | 做什么                                                                                                                                          |
|---|---------------------|-------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | `version` 校验      | 去空白与不可打印字符，空值回落 `latest`，再用白名单校验是否为 Alpine 版本号，不合法直接 `exit 1`                                                |
| 2 | 登录                | `docker login` 到 `${CNB_DOCKER_REGISTRY}`，凭证来自 `imports` 引入的组织环境                                                                   |
| 3 | buildx 自检         | `docker buildx version` / `inspect`，并探测当前 buildx 是否支持 `--provenance`                                                                  |
| 4 | 解析基座            | 选 `<仓库 slug>:latest` / `:3.24` / `:3.24.3` → 容器内读 `/etc/alpine-release` 得实际版本 → 取该版本标签的 index digest；任何一步失败都直接退出 |
| 5 | 一次多架构构建      | `buildx build --platform linux/amd64,linux/arm64 --push`，推 `<alpine 版本>` 一个标签                                                           |
| 6 | 单平台标签          | 从 manifest list 取每个架构的清单 digest，`imagetools create` 打 `<alpine 版本>-linux-<arch>`                                                   |
| 7 | 冒烟 + 标签校验     | 跑 `chromium --version`、无头渲染 `about:blank`、时区断言，再校验 OCI `base.name` / `version` 两个标签                                          |
| 8 | 提升 minor / latest | 仅当 `dtapp/alpine:<同名标签>` 已指向本次基座 digest 时提升；否则跳过并打日志                                                                   |
| 9 | 汇总元数据          | digest / 两个平台的体积 / 基座信息 / `chromium_version` / `chromium_built_at` 写进 `.cnb/annotation.json`                                       |

每一步失败都显式退出：登录、基座解析、构建、单平台派生、冒烟、提升各自 `|| exit 1`，脚本不会留下「只有多架构、没有单平台」的半成品还继续写元数据。

与前一代流程的差别可以压缩成一句：以前是多次全量构建 × 多个变体，靠「同样的输入撞出同样的层」保证内容一致；现在是 1 次多架构构建，单平台标签就是 manifest list 里那份清单本身，一致性是构造出来的。第 8 步的基座对齐门闸则保证 Chromium 不会跑到基座前面。

每次构建产出的 5 个标签、`<alpine 版本>` 与 `latest` 的关系，见[镜像与标签](images-and-tags.md)；本地复现同一套构建命令见[构建与本地复现](build.md)。

## version 入参校验

`version` 是按钮上的输入（`web_trigger.yml` 里 `default: latest`），定时任务则恒为 `latest`。脚本对它的处理是「先清洗、再白名单」，两条都在任何 `buildx` 命令之前：

```bash
version=$(printf '%s' "${version}" | tr -d '[:space:]')   # 去空白
version=$(printf '%s' "${version}" | sed 's/[^[:print:]]//g')  # 去不可打印字符
[ -n "${version}" ] || version="latest"                   # 空值回落

if [ "${version}" != "latest" ]; then
  printf '%s' "${version}" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    || die "version 只接受 latest / 3.24 / 3.24.3，收到：${version}"
fi
```

| 输入                       | 结果                                                  |
|----------------------------|-------------------------------------------------------|
| 留空                       | `latest`                                              |
| `3.24` / `3.24.3`          | 只用于选基座标签；`ALPINE_VERSION` 用解析出的实际版本 |
| 前后带空格的 `3.24`        | 清洗后通过                                            |
| `v3.24`                    | `exit 1`：白名单要求首位是数字                        |
| `131`（Chromium 主版本号） | `exit 1`：没有小版本号，一眼能看出填错了对象          |
| `edge` / `main`            | `exit 1`                                              |

拦在这一步而不是让它走到 `FROM`，是因为这个入参是 **Alpine 版本**、不是 Chromium 版本：写成 `131` 会让基座解析去找 `<仓库 slug>:131`，buildx 只回一句拉不到镜像，很难一眼看出是「概念填错了」。校验通过后版本号只用于选基座；产物标签与 `##[set-output chromium_image_version=...]` 用的是从基座解析出来的实际版本，回看某次构建用的是哪个基础镜像时直接读这个值。

## 构建参数与缓存策略

三段参数决定「这次构建能不能拿到新东西」：`--pull`、attestation 开关、缓存。

| 参数                              | 作用                               | 不这么做会怎样                                                           |
|-----------------------------------|------------------------------------|--------------------------------------------------------------------------|
| `--pull`                          | 每次都去 registry 取一次基础镜像   | builder 复用缓存的旧基座层，基座标签已挪但它还没跟上                     |
| `--provenance=false --sbom=false` | 关掉 buildx 默认附加的 attestation | manifest list 里每个架构多出 attestation 条目，digest 与体积都要多绕一层 |
| CNB：**不用** registry 缓存       | 每轮重新装 184 个包 / 761 MiB      | 缓存命中后 `apk add` 不重跑，上游补丁进不来；还会多出 `buildcache*` 标签 |
| GitHub：`type=gha` + `CACHE_BUST` | Actions 缓存 + 每天变化的击穿点    | 没有跨轮次缓存，构建变慢；或在缓存命中时永远装到同一批包                 |

attestation 那两个参数不是无条件加的：buildx 0.10 以下不认 `--provenance`，直接加是硬失败，所以脚本先 `docker buildx build --help | grep -q -- '--provenance'` 探测，不支持就跳过并打一行「当前 buildx 不支持 --provenance」的告警。跳过时构建照常成功，只是体积解析可能取到 index——脚本对「`--raw` 里没有 `layers`」留了兜底路径，见[构建元数据与徽章](metadata-and-badges.md)。

**为什么 CNB 侧不再用 registry 缓存。** 启用跨轮次缓存后，装包层的缓存键由「本层指令 + 上层内容」算出：只要 Dockerfile 与那几个 `--build-arg` 不变，这一层永远命中，`apk add chromium` 一步都不会重跑，上游当天发的 chromium 补丁也就永远进不了镜像。用 `CACHE_BUST` 每天击穿可以解决正确性，但代价是制品库里多出三个 600–800 MiB 的 `buildcache*` 标签，而每日 cron 本来就要重装一次包——缓存省不下多少时间。所以 CNB 侧直接不用缓存：每天真的重装，标签列表也只剩镜像本身。GitHub 侧保留 `type=gha`（存在 Actions 缓存里，不占 GHCR 标签），并用 `CACHE_BUST` 每天击穿。

完整的一次调用（中性镜像；本地跑要先把 `IMAGE` 换成你有推送权的仓库并 `docker login`）：

```bash
IMAGE=docker.cnb.cool/dtapp/alpine/chromium
BASE=docker.cnb.cool/dtapp/alpine

docker buildx build \
  -t "${IMAGE}:3.24.3" \
  --platform linux/amd64,linux/arm64 \
  --pull --provenance=false --sbom=false \
  --build-arg CHROMIUM_BASE_IMAGE="${BASE}:3.24.3@sha256:<digest>" \
  --build-arg CHROMIUM_BASE_NAME="${BASE}:3.24.3" \
  --build-arg CHROMIUM_BASE_DIGEST=sha256:<digest> \
  --build-arg ALPINE_VERSION=3.24.3 \
  --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --build-arg BUILD_REVISION=$(git rev-parse --short HEAD) \
  -f .cnb/docker/Dockerfile.chromium --push .
```

GitHub 侧在同样的命令上追加：

```bash
  --build-arg CACHE_BUST=$(date -u +%Y%m%d) \
  --cache-from type=gha,scope=alpine-chromium \
  --cache-to type=gha,scope=alpine-chromium,mode=min,ignore-error=true
```

## 改动后的验证方式

构建流水线只有手动与定时两个入口，没有 PR 校验作业。改完 Dockerfile 或构建脚本后，验证方式是自己手动触发一次对应流水线（CNB 按钮 / `gh workflow run`），或按[构建文档](build.md)里的本地命令跑一次 amd64 构建；绿了才推。定时任务只负责每日跟随上游，不承担改动门禁。

## imports 与 source

构建相关的两段流水线（手动按钮、定时任务）只 `import` 组织环境，**不 import 构建脚本**：

```yaml
imports:
  - https://cnb.cool/dtapp/envs/-/blob/main/docker.yml
```

这一项来自组织 `envs` 仓库，提供构建所需的环境变量；凭证只以 `${CNB_TOKEN}`、`${CNB_TOKEN_USER_NAME}` 的形式出现在脚本里，真实值不进本仓库（见 [CONTRIBUTING](../../CONTRIBUTING.md)）。

脚本刻意留在仓库里、由 `source` 执行：`imports` 会对被引入的文件做变量处理，脚本里的 `${...}` 会被改写成带引号的字面量（CNB 上表现为 `sed: can't read "..."` 这类怪错）。Alpine 基础镜像那条流水线踩过这个坑，两条流水线现在都不再把脚本放进 `imports`。

真正执行发生在 stages 里，且必须用 `source`：

```bash
source .cnb/scripts/build-chromium.sh   # 正确：变量与输出留在当前 shell
sh .cnb/scripts/build-chromium.sh       # 错误：set-output 与 export 都随子进程消失
```

原因写在脚本头部：它要 `echo "##[set-output chromium_version=...]"`（以及 digest）把结果交给 CNB 采集，并在同一 shell 里维护登录态与 `trap cleanup EXIT`。换成 `sh` 执行，这些状态都留在子进程里，外层拿不到。

`version` 只影响一处：解析本仓库同名基座标签（`<仓库 slug>:<version>`）。`--build-arg ALPINE_VERSION` 与所有产物标签都用从基座容器里读出的实际版本，不是入参。基座确定后 Chromium 及其图形/渲染依赖由同一份 `.cnb/docker/Dockerfile.chromium` 固定，流水线里没有「指定 Chromium 版本」的入口。

## runner tags 与 docker 服务

```yaml
runner:
  tags: cnb:arch:amd64
services:
  - docker
```

`tags` 是调度条件：任务只会落到带 `cnb:arch:amd64` 标签的 Runner。arm64 产物也在这台 amd64 Runner 上产出，靠 CNB `services: docker` 内置的多架构 buildx 完成跨架构构建，所以不需要单独找 arm64 机器。

`services: docker` 同时提供 docker daemon 与现成的 builder。脚本里的 `docker buildx version`、`ls`、`inspect` 三段自检就是确认这一点。不要在脚本里 `docker buildx create --driver docker-container`：受限容器拉不起嵌套 buildkitd，会以 bootstrap 失败告终。

## stages 与 set-output

一次 stage 一个 `name`，两种形态：

- `script:` 内联 shell，构建步骤用它；
- `image:` 指定容器镜像加 `settings:`，插件步骤用它。

`##[set-output key=value]` 是 CNB 的 stage 输出语法，写出的值进入 stage 结果，供后续步骤和流水线界面读取。Chromium 脚本输出 `chromium_image_version` / `chromium_version` / `chromium_image_digest` 三个值；键带 `chromium_` 前缀是为了不和同仓库 Alpine 流水线的 `image_*` 互相覆盖。

## 插件职责

| 插件镜像                           | 出现位置                                | 职责与关键参数                                                                                                 |
|------------------------------------|-----------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `cnbcool/annotations:latest`       | `build-chromium.yml`、`.cnb.yml` `main` | `type: ADD` + `fromJsonFile: .cnb/annotation.json`，写 commit 元数据（键带 `chromium_` 前缀）                  |
| `cnbcool/codewiki:latest`          | `codewiki.yml`                          | 生成 Code Wiki，`git_doc_dir` 指定落盘目录，`timeout: 3h`                                                      |
| `cnbcool/knowledge-base`           | `knowledge-base.yml`                    | `include: '**/**.md'`、`issueSyncEnabled: true`、`ignoreProcessFailures: true`                                 |
| `cnbcool/sca-vulnerability:latest` | `sca.yml`                               | 组件漏洞扫描，`scanMode: full/diff`、`publish: true`；`failOnSeverity: high` 只在 `pull_request.target` 上启用 |
| `cnbcool/sca-license:latest`       | `sca.yml`                               | License 扫描，参数同上                                                                                         |
| `cnbcool/sca-sbom:latest`          | `sca.yml`                               | SBOM，`format: spdx`                                                                                           |
| `cnbcool/code-review:latest`       | `code-review.yml`                       | PR 上的 AI 评审，`comment`、`min_severity`、`exclude_categories`、`model` 等                                   |
| `cnbcool/cnb-sechook`              | `cnb-sechook.yml`                       | 汇总扫描结果与敏感信息统计，`max_display_authors: 5`                                                           |
| `cnbcool/code-security-config`     | `code-security-config.yml`              | `args: [validate]`，校验扫描配置本身合法                                                                       |

扫描策略与忽略规则见[安全基线](security-baseline.md)，插件参数排错见[排错手册](troubleshooting.md)。

## web_trigger.yml：按钮与权限

按钮定义在 `branch.buttons` 下，字段固定为 `name`、`description`、`event`、`permissions.roles`，可选 `inputs`：

| 按钮                                       | event                        | 权限                       | 输入                                                                                                                             |
|--------------------------------------------|------------------------------|----------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| 打包 Alpine 镜像（多架构 amd64 + arm64）   | `web_trigger_build_alpine`   | owner / master / developer | `version`，`required: false`，`default: ''`                                                                                      |
| 打包 Chromium 镜像（多架构 amd64 + arm64） | `web_trigger_build_chromium` | owner / master / developer | `version`（Alpine 版本，留空 = 跟随基座 latest）、`expected_chromium_major`（主版本断言，留空 = 不校验，可填具体主版本或 `any`） |
| 生成 Code Wiki                             | `web_trigger_codewiki`       | owner / master / developer | 无                                                                                                                               |

`event` 与 workflow 文件里的事件键是同一个字符串：两边字面量不一致，按钮点下去就不会产生流水线。`inputs` 里的 key 直接变成脚本读到的小写变量 `version`。

## 新增或修改流水线

1. 改 `.cnb/workflows/` 下的文件，根键 `'**'`，事件名下一层放流水线数组；
2. 新增文件必须加进 `.cnb.yml` 的 `include`，忘记就等于没写；改已有文件不需要动 `include`；
3. 需要手动入口时在 `.cnb/web_trigger.yml` 加按钮，`event` 与 workflow 事件键逐字一致，权限只给需要的角色；
4. 改事件名要同时改 `web_trigger.yml`、`include` 引用与文档，改 inputs 要同时改脚本里读变量的地方；
5. 推送逻辑改动落在 `.cnb/scripts/build-chromium.sh`，失败必须显式 `exit 1`；提交前跑 `make format`；
6. 改 Dockerfile 的装包逻辑后没有 PR 自动校验兜底，先本地构建或手动触发一次流水线验证，再合并。

## 典型失败与排查入口

| 症状                                  | 常见原因                                                                               | 先看哪里                                         |
|---------------------------------------|----------------------------------------------------------------------------------------|--------------------------------------------------|
| 点按钮没有任何流水线产生              | `web_trigger.yml` 的 `event` 与 workflow 事件键不一致，或该 workflow 不在 `include` 里 | 按钮定义、`include` 列表                         |
| `❌ version 只接受…`                  | 填了 Chromium 版本号或非 Alpine 版本号（`131`、`v3.24`、`edge`）                       | 构建步骤日志第一行、输入值                       |
| `❌ 找不到基座 <仓库 slug>:<version>` | 基座流水线还没产出该标签，或手动版本在基座侧从未构建过                                 | 构建日志「基座引用 / 基座」行；先跑 build-alpine |
| `FROM` 阶段拉不到基础镜像             | 基座引用无效；本地则可能是 Docker Hub 上没有这个 alpine tag                            | 构建步骤日志的 `FROM` 行                         |
| buildx bootstrap 失败                 | 脚本里自建了 docker-container builder                                                  | 脚本的 buildx 自检段输出                         |
| 构建长时间停在 `apk add`              | Chromium 与图形依赖合计数百 MB，首次无缓存时下载慢                                     | 构建日志的包下载进度                             |
| 单平台标签缺失                        | 某个架构的清单 digest 取不到（该架构构建/推送失败，或 attestation 没关掉）             | 日志里「取不到 … 的平台清单 digest」             |
| 徽章显示 `unknown`                    | 元数据解析失败（体积记 `-1`），或 digest / `chromium_version` 未取到                   | 日志里的「体积解析失败」行                       |
| 定时任务不生效                        | 定时任务只在 `main` 顶层键下声明，改在其它分支上不会生效                               | `.cnb.yml`、默认分支内容                         |

排查入口：

```text
流水线运行记录   https://cnb.cool/dtapp/alpine/-/pipeline
定时任务状态     https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/status/crontab
本次流水线配置   https://cnb.cool/dtapp/alpine/-/blob/main/.cnb.yml
commit 元数据    https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_image_digest
```

## 相关文档

- [CNB 平台层说明](../cnb.md)（内置变量与地址来源、按钮/imports/元数据总览）
- [GitHub Actions 与 GHCR](../github.md)（另一个平台的两份副本）
- [仓库架构](architecture.md)
- [镜像与标签](images-and-tags.md)
- [构建与本地复现](build.md)
- [构建元数据与徽章](metadata-and-badges.md)
- [安全基线](security-baseline.md)
