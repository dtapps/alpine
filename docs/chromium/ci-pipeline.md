# CI 流水线

> `.cnb.yml` 只负责 `include` 与定时任务，每个事件的具体步骤分散在 `.cnb/workflows/*.yml`；这里讲清这套组织方式、事件与 workflow 的逐条对应、构建流水线的九个步骤与它的入参校验/缓存击穿、PR 上的镜像校验门禁，以及改动流水线时必须同步的位置。

## 为什么拆成 include

一条流水线要同时承载构建、扫描、评审、文档生成、知识库同步五类互不相关的事情。全塞进 `.cnb.yml` 会得到一份几百行、谁都不敢动的文件，所以按「一个事件一组职责」拆成 8 个文件，`.cnb.yml` 只保留两件事：`include` 列表和 `main` 上的定时任务。改 SCA 阈值不会碰到构建脚本，改构建不会误删评审配置。

仓库合并后这里有两套构建流水线互不干扰：`build-alpine.yml`（Alpine 基础镜像，`web_trigger_build_alpine` + `crontab: 5 0 * * *`）与 `build-chromium.yml`（本篇的 Chromium 镜像，`web_trigger_build_chromium` + `crontab: 30 1 * * *`）。两条 cron 刻意错峰：chromium 三变体多架构构建比 Alpine 基础镜像重得多。

代价是触发关系不再集中在一处：某个事件到底跑哪些步骤，需要跨文件看。下表就是用来补这个信息。

## 配置的三层结构

```yaml
include:
  - .cnb/workflows/build-alpine.yml
  - .cnb/workflows/build-chromium.yml
  # ... 共 8 个文件

main:
  'crontab: 5 0 * * *':   # Alpine 基础镜像
    - name: build-alpine
      stages:
        - name: 构建并推送多架构镜像
          script: |
            source .cnb/scripts/build-alpine.sh
  'crontab: 30 1 * * *':  # Chromium 镜像（错峰）
    - name: build-chromium
      stages:
        - name: 构建并推送多架构镜像
          script: |
            source .cnb/scripts/build-chromium.sh
```

两层键决定「什么时候跑」：

- 顶层键是分支过滤器。`.cnb.yml` 里定时任务挂在 `main` 下，只对默认分支生效；8 个 workflow 文件统一用 `'**'`，对所有分支生效。
- 事件名在过滤器下一层，值是流水线数组。`push`、`pull_request`、`tag_push`、`issue.open`、`web_trigger_build_chromium` 都是同级事件键；定时事件把 cron 表达式写进键名并加引号（`'crontab: 30 1 * * *'`），因为键值里有空格和 `*`。

## 事件与 workflow 对应表

| 事件                                                | 定义位置                                                                                       | 产物                                                                                                                                                                        |
|-----------------------------------------------------|------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `web_trigger_build_chromium`                        | `workflows/build-chromium.yml`                                                                 | 1 次多架构 `buildx build --push` × 3 个变体（default / `-cjk` / `-headless`），冒烟通过后再由 `imagetools create` 打每个变体 × 两个架构的单平台标签；`.cnb/annotation.json` |
| `'crontab: 30 1 * * *'`                             | `.cnb.yml` 的 `main`                                                                           | 同上，但 `version` 恒为 `latest`，不产生版本标签                                                                                                                            |
| `web_trigger_build_alpine` / `'crontab: 5 0 * * *'` | `workflows/build-alpine.yml`、`.cnb.yml` 的 `main`                                             | 另一条流水线：Alpine 基础镜像，与本篇无关（见 [Alpine 基础镜像文档](../alpine/index.md)）                                                                                   |
| `tag_push`                                          | `workflows/codewiki.yml`                                                                       | `${CNB_BUILD_WORKSPACE}/${CNB_REPO_SLUG}/codewiki` 下的 Code Wiki                                                                                                           |
| `web_trigger_codewiki`                              | `workflows/codewiki.yml`                                                                       | 同上                                                                                                                                                                        |
| `push`                                              | `workflows/sca.yml`、`workflows/knowledge-base.yml`                                            | SCA 全量报告附件、知识库索引                                                                                                                                                |
| `pull_request`                                      | `workflows/code-review.yml`、`workflows/cnb-sechook.yml`、`workflows/code-security-config.yml` | PR 评论、扫描与敏感信息统计、扫描配置校验结果                                                                                                                               |
| `pull_request`                                      | `workflows/build-chromium.yml`（`validate-chromium`）                                          | 镜像校验：`--load` 构建 amd64 + 三次冒烟，不推送，失败即门禁失败                                                                                                            |
| `pull_request.target`                               | `workflows/sca.yml`                                                                            | 增量扫描，`failOnSeverity: high` 时门禁失败                                                                                                                                 |
| `issue.open` / `issue.comment`                      | `workflows/knowledge-base.yml`                                                                 | 知识库同步                                                                                                                                                                  |

`push` 在两个文件里各声明一次，一次 push 会同时拉起 SCA 全量扫描与知识库构建，两段互不依赖；`tag_push` 与 `web_trigger_codewiki` 在 `codewiki.yml` 里是两份内容相同的流水线，改生成参数必须同步两处。`sca.yml` 不响应普通 `pull_request`，PR 上只有 `pull_request.target` 那一段（增量 + `failOnSeverity: high` 门禁）；`push` 侧的全量扫描刻意把 `failOnSeverity` 留在注释状态——上游未修的 CVE 必然出现在全量报告里，设门禁只会让每次 push 常红，失去「留一份基线」的意义，理由见[安全基线](security-baseline.md)。

`pull_request` 在表里出现多行，是同一个事件被多个文件各自声明：`build-chromium.yml` 只做镜像校验（`validate-chromium`，见下文），`code-review.yml` 等三个文件做评审与扫描。两段互不依赖，PR 上并行跑。

## 构建流程

`build-chromium.sh` 用一次多架构构建产出三个变体，单平台标签不再重新构建。按脚本的执行顺序：

| # | 步骤                       | 做什么                                                                                             |
|---|----------------------------|----------------------------------------------------------------------------------------------------|
| 1 | `version` 校验             | 去空白与不可打印字符，空值回落 `latest`，再用白名单校验是否为 Alpine 版本号，不合法直接 `exit 1`   |
| 2 | 登录                       | `docker login` 到 `${CNB_DOCKER_REGISTRY}`，凭证来自 `imports` 引入的组织环境                      |
| 3 | buildx 自检                | `docker buildx version` / `ls` / `inspect` 三段，并探测当前 buildx 是否支持 `--provenance`         |
| 4 | default 变体               | `buildx build --platform linux/amd64,linux/arm64 --push`，一次产出多架构 manifest list             |
| 5 | `-cjk` 变体                | 同一个 Dockerfile 加 `--build-arg WITH_CJK=1`                                                      |
| 6 | 取 default 的 index digest | `imagetools inspect "${IMAGE}:latest" --format '{{.Manifest.Digest}}'`，作为下一步的基座           |
| 7 | `-headless` 变体           | `Dockerfile.headless` + `--build-arg BASE_IMAGE=<image>@<digest>`，按 digest 钉住第 6 步的产物     |
| 8 | 单平台标签                 | 从 manifest list 取每个架构的清单 digest，`imagetools create` 直接打 `latest<suffix>-linux-<arch>` |
| 9 | 汇总元数据                 | digest / 两个平台的体积 / `chromium_version` / `chromium_built_at` 写进 `.cnb/annotation.json`     |

每一步失败都显式退出：登录、三个变体、单平台标签各自 `|| exit 1`，脚本不会留下「只有多架构、没有单平台」的半成品还继续写元数据。第 8 步是例外：某个架构的 digest 取不到时只跳过该标签并打一行告警，因为多架构产物已经推成功了。

与前一代流程的差别可以压缩成一句：以前是三次全量构建（多架构 + amd64 + arm64），靠「同样的输入撞出同样的层」保证内容一致；现在是 1 次多架构构建 × 3 个变体，单平台标签就是 manifest list 里那份清单本身，一致性是构造出来的。代价是第 8 步依赖 `imagetools` 的解析结果，看到「取不到 latest…/amd64 的平台清单 digest」这类告警，说明该架构的清单没进 manifest list。

三个变体各自产出哪些标签、`<version>` 与 `latest` 的关系，见[镜像与标签](images-and-tags.md)；本地复现同一套构建命令见[构建与本地复现](build.md)。

## version 入参校验

`version` 是按钮上的输入（`web_trigger.yml` 里 `default: latest`），定时任务则恒为 `latest`。脚本对它的处理是「先清洗、再白名单」，两条都在任何 `buildx` 命令之前：

```bash
version=$(echo "$version" | tr -d '[:space:]' | tr -d '\n\r')  # 去空白与换行
version=$(echo "$version" | sed 's/[^[:print:]]//g')          # 去不可打印字符
[ -z "$version" ] && version="latest"                        # 空值回落

case "$version" in
  latest) ;;
  [0-9]*.[0-9]*) ;;
  *)
    echo "❌ version 只接受 latest 或 3.24 / 3.24.3 这类 Alpine 版本号，收到: ${version}"
    echo "   提示：这里填的是 Alpine 版本，不是 Chromium 版本"
    exit 1
    ;;
esac
```

| 输入                       | 结果                                         |
|----------------------------|----------------------------------------------|
| 留空                       | `latest`                                     |
| `3.24` / `3.24.3`          | 原样作为 `--build-arg ALPINE_VERSION`        |
| 前后带空格的 `3.24`        | 清洗后通过                                   |
| `v3.24`                    | `exit 1`：白名单要求首位是数字               |
| `131`（Chromium 主版本号） | `exit 1`：没有小版本号，一眼能看出填错了对象 |
| `edge` / `main`            | `exit 1`                                     |

拦在这一步而不是让它走到 `FROM`，是因为这个入参是 **Alpine 版本**、不是 Chromium 版本：写成 `131` 会变成 `FROM alpine:131`，buildx 只回一句拉不到镜像，很难一眼看出是「概念填错了」。校验通过后版本号经 `##[set-output interior_version=...]` 交给流水线界面，回看某次构建用的是哪个基础镜像时直接读这个值。

## 构建参数与缓存击穿

三段参数决定「这次构建能不能拿到新东西」：`--pull`、attestation 开关、registry 缓存。

| 参数                                        | 作用                                                         | 不这么做会怎样                                                           |
|---------------------------------------------|--------------------------------------------------------------|--------------------------------------------------------------------------|
| `--pull`                                    | 每次都去 registry 取一次基础镜像                             | builder 复用它缓存的旧 `alpine:3.24.3` 层，上游补丁层进不来              |
| `--provenance=false --sbom=false`           | 关掉 buildx 默认附加的 attestation                           | manifest list 里每个架构多出 attestation 条目，digest 与体积都要多绕一层 |
| `--cache-from/--cache-to type=registry`     | `ref=<image>:buildcache<suffix>`、`mode=min`，三个变体各一份 | 每轮从零装 184 个包 / 761 MiB，构建时间成倍增加                          |
| `--build-arg CACHE_BUST=$(date -u +%Y%m%d)` | 写在装包层第一条 `echo` 里，按天变化，只让这一层失效         | 见下文「为什么必须击穿」                                                 |

attestation 那两个参数不是无条件加的：buildx 0.10 以下不认 `--provenance`，直接加是硬失败，所以脚本先 `docker buildx build --help | grep -q -- '--provenance'` 探测，不支持就跳过并打一行「当前 buildx 不支持 --provenance」的告警。跳过时构建照常成功，只是体积解析可能取到 index——脚本对「`--raw` 里没有 `layers`」留了兜底路径，见[构建元数据与徽章](metadata-and-badges.md)。

**为什么必须击穿。** 启用跨轮次的 registry 缓存之后，装包层的缓存键由「本层指令 + 上层内容」算出：只要 Dockerfile 与那几个 `--build-arg` 不变，这一层永远命中，`apk add chromium` 一步都不会重跑，上游当天发的 chromium 补丁也就永远进不了镜像。`CACHE_BUST` 每天变一次，等于给装包层一个每日失效点：最坏延迟一天，代价是每天重装一次包。它只写在装包层的第一条命令里，改 Dockerfile 其它部分（时区、用户、标签）不会连带重装 chromium。

完整的一次调用（default 变体；本地跑要先把 `IMAGE` 换成你有推送权的仓库并 `docker login`）：

```bash
IMAGE=docker.cnb.cool/dtapp/alpine/chromium

docker buildx build \
  -t "${IMAGE}:latest" \
  --platform linux/amd64,linux/arm64 \
  --pull --provenance=false --sbom=false \
  --build-arg ALPINE_VERSION=3.24.3 \
  --build-arg BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --build-arg BUILD_REVISION=$(git rev-parse --short HEAD) \
  --build-arg CACHE_BUST=$(date -u +%Y%m%d) \
  --cache-from "type=registry,ref=${IMAGE}:buildcache" \
  --cache-to "type=registry,ref=${IMAGE}:buildcache,mode=min" \
  -f .cnb/docker/Dockerfile.chromium --push .
```

`-cjk` 变体的缓存 ref 是 `buildcache-cjk`，`-headless` 是 `buildcache-headless`：`suffix` 与变体一一对应，切变体时不会把别人的层当成自己的缓存。

## PR 校验流水线 validate-chromium

`pull_request` 事件上多了一条 `validate-chromium`，定义在 `.cnb/workflows/build-chromium.yml`。它和推送流水线刻意不同：

| 维度 | `validate-chromium`（PR）       | `build-alpine`（按钮 / 定时）                          |
|------|---------------------------------|--------------------------------------------------------|
| 平台 | 只有 `linux/amd64`              | `linux/amd64` + `linux/arm64`                          |
| 输出 | `--load` 到 Runner 本地，不推送 | `--push` 三个变体 + 每个变体两个单平台标签             |
| 凭证 | 不需要 registry 登录            | 需要 `CNB_TOKEN` 推制品库                              |
| 冒烟 | 三次（见下）                    | 三次（同一组断言），失败则不派生单平台标签、不写元数据 |
| 耗时 | 短：单平台、只装一次包          | 长：三个变体 × 两个架构                                |

三次冒烟都是「起容器、跑一条命令、看退出码」：

```bash
# 1) 二进制在、版本对
docker run --rm alpine-chromium:pr chromium --version

# 2) 渲染栈可用：不联网、不写文件，秒回
docker run --rm --shm-size=1g alpine-chromium:pr \
  chromium --headless --no-sandbox --disable-dev-shm-usage \
  --dump-dom about:blank

# 3) 时区生效
docker run --rm alpine-chromium:pr date +%Z | grep -q 'CST'
```

它是**门禁**：改坏 Dockerfile（包名写错、源路径拼错、时区文件挪了位置）以前只能等次日 `01:30` 的定时任务变红才发现，中间那段时间 `latest` 一直是上一版；现在 PR 上就能红，而且不推送、不碰制品库，失败成本只剩一次 amd64 构建。

两处细节容易漏：那条构建命令里 `ALPINE_VERSION` 写死 `3.24.3`（与 Dockerfile 默认值一致），不读按钮上的 `version`，也不 `import` 组织环境与构建脚本——它要能在一个没有推送凭证的 PR 环境里独立跑完。它也不验证 `-cjk` / `-headless` 变体与多架构，绿了只代表「这份 Dockerfile 装得完、浏览器起得来、时区对」。

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

`version` 只影响 `--build-arg ALPINE_VERSION`，也就是基础镜像是 `alpine:3.24` 还是 `alpine:latest`；Chromium 及其图形/渲染依赖由同一份 `.cnb/docker/Dockerfile.chromium` 固定，流水线里没有「指定 Chromium 版本」的入口。

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

`##[set-output key=value]` 是 CNB 的 stage 输出语法，写出的值进入 stage 结果，供后续步骤和流水线界面读取。脚本只输出一个 `interior_version`，紧接着用同名大写的环境变量给后续命令用，两者职责不同，不要混用。

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

| 按钮                                       | event                        | 权限                       | 输入                                                                                                                   |
|--------------------------------------------|------------------------------|----------------------------|------------------------------------------------------------------------------------------------------------------------|
| 打包 Alpine 镜像（多架构 amd64 + arm64）   | `web_trigger_build_alpine`   | owner / master / developer | `version`，`required: false`，`default: ''`                                                                            |
| 打包 Chromium 镜像（多架构 amd64 + arm64） | `web_trigger_build_chromium` | owner / master / developer | `version`（Alpine 版本，留空 = latest）、`expected_chromium_major`（主版本断言，留空 = Dockerfile 的 155，可填 `any`） |
| 生成 Code Wiki                             | `web_trigger_codewiki`       | owner / master / developer | 无                                                                                                                     |

`event` 与 workflow 文件里的事件键是同一个字符串：两边字面量不一致，按钮点下去就不会产生流水线。`inputs` 里的 key 直接变成脚本读到的小写变量 `version`。

## 新增或修改流水线

1. 改 `.cnb/workflows/` 下的文件，根键 `'**'`，事件名下一层放流水线数组；
2. 新增文件必须加进 `.cnb.yml` 的 `include`，忘记就等于没写；改已有文件不需要动 `include`；
3. 需要手动入口时在 `.cnb/web_trigger.yml` 加按钮，`event` 与 workflow 事件键逐字一致，权限只给需要的角色；
4. 改事件名要同时改 `web_trigger.yml`、`include` 引用与文档，改 inputs 要同时改脚本里读变量的地方；
5. 推送逻辑改动落在 `.cnb/scripts/build-chromium.sh`，失败必须显式 `exit 1`；提交前跑 `make format`；
6. 改 Dockerfile 的装包逻辑时，顺手核对 `build-chromium.yml` 里 `validate-chromium` 的构建参数、路径门禁与三次冒烟是否仍然成立（它不 import 构建脚本，是独立的一份）。

## 典型失败与排查入口

| 症状                         | 常见原因                                                                               | 先看哪里                             |
|------------------------------|----------------------------------------------------------------------------------------|--------------------------------------|
| 点按钮没有任何流水线产生     | `web_trigger.yml` 的 `event` 与 workflow 事件键不一致，或该 workflow 不在 `include` 里 | 按钮定义、`include` 列表             |
| `❌ version 只接受…`         | 填了 Chromium 版本号或非 Alpine 版本号（`131`、`v3.24`、`edge`）                       | 构建步骤日志第一行、输入值           |
| `FROM` 阶段拉不到基础镜像    | 校验通过，但 Docker Hub 上没有这个 alpine tag（例如尚未发布的 `3.25`）                 | 构建步骤日志的 `FROM` 行             |
| buildx bootstrap 失败        | 脚本里自建了 docker-container builder                                                  | 脚本的 buildx 自检段输出             |
| 构建长时间停在 `apk add`     | Chromium 与图形依赖合计数百 MB，首次无缓存时下载慢                                     | 构建日志的包下载进度                 |
| 单平台标签缺失               | 某个架构的清单 digest 取不到（该架构构建/推送失败，或 attestation 没关掉）             | 日志里「取不到 … 的平台清单 digest」 |
| PR 上 `validate-chromium` 红 | Dockerfile 改坏：装包失败、浏览器起不来、时区丢了                                      | 该 stage 的构建日志与三次冒烟输出    |
| 徽章显示 `unknown`           | 元数据解析失败（体积记 `-1`），或 digest / `chromium_version` 未取到                   | 日志里的「体积解析失败」行           |
| 定时任务不生效               | 定时任务只在 `main` 顶层键下声明，改在其它分支上不会生效                               | `.cnb.yml`、默认分支内容             |

排查入口：

```text
流水线运行记录   https://cnb.cool/dtapp/alpine/-/pipeline
定时任务状态     https://cnb.cool/dtapp/alpine/-/badge/git/latest/ci/status/crontab
本次流水线配置   https://cnb.cool/dtapp/alpine/-/blob/main/.cnb.yml
commit 元数据    https://cnb.cool/dtapp/alpine/-/badge/annotation/commit/latest/chromium_image_digest
```

## 相关文档

- [仓库架构](architecture.md)
- [镜像与标签](images-and-tags.md)
- [构建与本地复现](build.md)
- [构建元数据与徽章](metadata-and-badges.md)
- [安全基线](security-baseline.md)
