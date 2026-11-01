# 排错手册

> 按症状查：先在总表里定位到主题与对应文档，再跳到本册对应小节复制命令；每条都给出原因、可执行处置和延伸阅读。

## 症状总表

| 症状                                  | 可能原因                                                         | 处置                                             | 对应文档                               |
|---------------------------------------|------------------------------------------------------------------|--------------------------------------------------|----------------------------------------|
| 脚本报 `version` 非法                 | 输入不是 latest / `3.25` / `3.25.1` / `3.25.1@sha256:<64hex>     | 按白名单改成合法形态                             | [镜像与标签](images-and-tags.md)       |
| `FROM` 阶段拉不到基础镜像             | `version` 填了不存在的 tag、或到上游网络不通                     | 换真实存在的 tag，用 `latest` 对照网络           | [构建](build.md)                       |
| 解析不到基座版本                      | 一次性容器拉不到 `alpine:latest`，或读不到版本文件               | 确认 Runner 出网与 docker 服务，重试             | [CI 流水线](ci-pipeline.md)            |
| `apk add` 拉索引超时或 404            | 新 minor 的 `vX.Y` 路径腾讯云未同步（CNB）、官方源故障（GitHub） | 确认源主机与路径，等同步或临时补源               | [APK 源与网络](mirrors.md)             |
| buildx 报 bootstrap 失败              | 自建了 `docker-container` builder                                | 删掉自建 builder，用 CNB 内置 builder            | [构建](build.md)                       |
| push 返回 401 / 403                   | token 缺失或过期 / 无该仓库写权限                                | 核对 `imports` 与 registry 地址                  | [CI 流水线](ci-pipeline.md)            |
| 冒烟失败、`latest` 没更新             | 基座版本前缀不符、时区、源行数、命令缺失或 OCI 标签不符          | 按断言逐项修，修好重跑即可                       | [CI 流水线](ci-pipeline.md)            |
| 元数据里 digest 是 `unknown`          | 取不到 manifest digest，或元数据步骤没跑                         | 手动 `imagetools inspect` 复核                   | [构建元数据](metadata-and-badges.md)   |
| 构建日志出现「APK 索引解析失败」      | 一次性容器里 `apk update` 失败（网络或源不可达）                 | 本次自动降级为 `CACHE=off`，修好网络后重跑即可   | [缓存实现](../cache-implementation.md) |
| 带缓存的构建在推送后失败              | registry 不接受 buildx 缓存清单                                  | 脚本会自动去掉缓存重试；反复出现就传 `CACHE=off` | [缓存实现](../cache-implementation.md) |
| 徽章灰色或显示 `unknown`              | key 拼错、annotation 未写入、看错 commit                         | 对照十二个 key 与写入步骤                        | [构建元数据](metadata-and-badges.md)   |
| 体积显示 `unknown`                    | 取到的清单里没有 `layers` 字段（拿到的是 index）                 | 先按平台清单 digest 再取 `--raw`                 | [构建元数据](metadata-and-badges.md)   |
| 单平台标签指向的清单与 index 条目不同 | 派生步骤没用 `imagetools create`（退回成重新构建）               | 核对 digest，重建走派生路径                      | [镜像与标签](images-and-tags.md)       |
| 容器内时间是 UTC                      | 时区未生效，`/etc/localtime` 被覆盖或删了 tzdata                 | 检查时区文件与 `TZ` 变量                         | [Dockerfile 解析](dockerfile.md)       |
| `make format` 报 command not found    | 本机缺四个格式化工具之一                                         | 按工具链文档安装                                 | [格式化](formatting.md)                |
| 页面没有构建按钮 / 点了不触发         | 按钮 `event` 与 workflow 触发键不一致或未 include                | 三处事件名对齐                                   | [CI 流水线](ci-pipeline.md)            |
| PR 被 SCA 拦住                        | `failOnSeverity: high` 命中 high 及以上漏洞                      | 升级包或确认误报，不要关掉门禁                   | [安全基线](security-baseline.md)       |

## 构建阶段

### 脚本报 `version` 非法

`build-alpine.sh` 先做白名单校验，再动任何 docker 命令：留空或 `latest` 表示跟随 `Dockerfile` 的 `ALPINE_VERSION`（默认 `latest`），其余只接受 `3.25`、`3.25.1`、`3.25.1@sha256:<64 位 hex>` 这三种形态。以下输入都会在校验阶段 `exit 1`：

| 输入                                | 为什么被拒                                             |
|-------------------------------------|--------------------------------------------------------|
| `v3.25`、`3.25-alpine`              | 带字母或连字符，不是合法的 alpine tag                  |
| `3.25/`、`3.25:latest`              | 含 `/`、`:`（digest 那处 `@sha256:` 除外），会污染引用 |
| `3.25.1@sha256:abc`（非 64 位 hex） | digest 格式不完整，拼进 `FROM` 会拉不到                |
| 含空格、换行的值                    | 会被当成两个参数或污染标签名                           |

处置：改成 `latest`、`3.25`、`3.25.1` 或完整的 `3.25.1@sha256:<64hex>`。这一步失败时还没有任何网络请求，所以报错时间点极早，看到的就是校验逻辑而不是构建。

### `FROM` 拉取失败

`version` 通过校验后仍可能失败，原因只有两类：这个 tag 在 Docker Hub 上不存在（例如只发到 `3.25` 而你写成了 `3.25.9` 这种不存在的补丁号），或 Runner 到 Docker Hub 的网络不通。先区分：

```bash
# 1) 目标 tag 是否存在
docker buildx imagetools inspect alpine:3.25.1
# 2) 用 latest 对照：latest 也失败说明是网络问题
docker buildx imagetools inspect alpine:latest
```

处置：`version` 填 `latest`、`3.25`、`3.25.1` 这类真实标签。定时任务不传 `version`，走的就是 `Dockerfile` 默认的 `latest`；若它连续失败而手动构建成功，问题在 Runner 出网而不是版本号。

### `apk add` 拉索引超时或 404

Dockerfile 已经不用 `apk update`：`apk add --no-cache` 自带索引拉取，省掉一整轮索引下载。所以报错出现在唯一 那个 `RUN` 的 `apk add` 行。源路径不在本仓库手写：基座自带的 `/etc/apk/repositories` 已经是 `vX.Y` 的 `main` + `community` 两行，Dockerfile 只用 `sed` 换主机名（CNB 换成腾讯云，GitHub 不换）：

```bash
docker run --rm alpine:latest sh -c 'cat /etc/alpine-release; cat /etc/apk/repositories'
```

看到报错 URL 里的主机不是预期的那一个，说明换源没生效或被人为改过：CNB 侧检查 `sed` 是否命中 `dl-cdn.alpinelinux.org`，GitHub 侧检查是否有人加了换源步骤。只剩 404 而主机正确，是源站尚未同步该 minor：CNB 侧 `/etc/apk/repositories` 是腾讯云主机的 `main` + `community` 两行，没有跨站兜底，腾讯云没同步时 `apk add` 会直接失败；GitHub 侧是官方源的两行。处置是等源站同步；临时换源属于对外行为变更，需要在 PR 里说明，不要在构建脚本里零散堆源。`community` 已经在这两行里，装 community 的包不需要额外加源。

### buildx bootstrap 失败

不要自建 builder。CNB 的 `services: docker` 默认已内置可做多架构的 buildx builder：

```bash
docker buildx version
docker buildx ls
docker buildx inspect
```

`build-alpine.sh` 在唯一一次构建之前会跑 `version` 与 `inspect` 两条自检（`ls` 留给人工排查）。若在受限容器里执行过 `docker buildx create --driver docker-container`，会因拉不起嵌套 buildkitd 而 bootstrap 失败：删掉该 builder，回到内置的实例，同时确认 workflow 里声明了 `services: docker`。

## 推送与制品库

### push 401 / 403

401 是认证失败，403 是认证通过但没有目标仓库的写权限。

```bash
# 变量是否注入（imports 引入的环境变量）
printf '%s\n' "${CNB_DOCKER_REGISTRY}" "${CNB_TOKEN_USER_NAME}"
# 手动复现登录（本地复现请换自己 fork 的地址）
printf '%s' "${CNB_TOKEN}" | docker login -u "${CNB_TOKEN_USER_NAME}" --password-stdin "${CNB_DOCKER_REGISTRY}"
```

凭证来自 `imports` 里引入的组织密钥仓库，仓库内没有任何字面量。脚本用 `--password-stdin` 而不是 `-p`：`-p` 把 token 留在进程列表和 shell 历史里，构建日志、`ps`、审计记录都可能带上它。缺变量通常是 `imports` 那一行被删 或路径写错（`set -u` 会让未定义变量直接失败，不会带着空密码继续）；能登录但 403 则是账号对该仓库没有推送权限。 不要拿线上路径 `docker.cnb.cool/dtapp/alpine` 做实验性推送。

脚本结束时 `trap` 会删掉 `${HOME}/.docker/config.json`，避免把登录态留在 Runner 上；本地复现时如果看到「已登录 但权限不对」，先检查是不是上一次的凭证缓存还在。

### manifest list 与单平台标签的误读

| 标签                              | 承诺的平台范围 | 对象来源                                       |
|-----------------------------------|----------------|------------------------------------------------|
| `3.25.1`、`latest`、`3.25`        | amd64 + arm64  | 唯一一次构建产出的 manifest list               |
| `3.25.1-linux-amd64` 等单平台标签 | 单一平台       | `imagetools create` 从上面 index 派生的 digest |

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:3.25.1
docker manifest inspect docker.cnb.cool/dtapp/alpine:3.25.1-linux-amd64
```

第一行能看到 `linux/amd64` 与 `linux/arm64` 两个条目；第二行只承诺 amd64，它指向的就是第一行里 amd64 条目 那一份镜像清单，digest 完全相同。两者不是「两份内容相近的镜像」，也不存在「多架构合并失败」这种故障—— digest 对不上才说明派生步骤出了问题（例如退回成又构建了一次）。

真正要小心的是体积统计：把 index 的条目 `size` 相加得到的是几 KB 的假值，必须按平台清单取层体积， 见下文「体积显示 `unknown`」。

### 冒烟测试失败

脚本在提升 `latest` 之前跑六项断言，失败会直接 `exit 1`，`latest` 与 `<minor>` 保持不动。此时版本标签（如 `3.25.1`）已经指向那份坏产物了（构建阶段就推了），这是排查线索而不是故障：按 `latest`/`3.25` 拉取的下游不受影响，重新构建成功后会把它覆盖回来。

| 断言失败                                        | 常见原因                                                              |
|-------------------------------------------------|-----------------------------------------------------------------------|
| `/etc/alpine-release` 前缀不是 `${ALPINE_REAL}` | 解析出的版本与真正拉到的基座不一致（代理缓存、tag 漂移、多平台选中）  |
| `/etc/timezone` 不是 `Asia/Shanghai`            | `RUN` 里写时区那两行被删或顺序错了                                    |
| `date +%z` 不是 `+0800`                         | 只写了 `/etc/timezone`，漏了 `/etc/localtime` 的符号链接              |
| `/etc/apk/repositories` 不是 2 行               | 换源时重写了整份文件、少写 `main` 或 `community`，或多了空行          |
| `curl`/`drill`/`git`/`nc`/`nslookup` 缺失       | 包名写错（习惯性写 `dig`/`bind-tools`），或删包时没同步改断言         |
| OCI 标签 `version` 与 `${STAMP}` 不符           | `--build-arg IMAGE_VERSION` 没传到，或 Dockerfile 的 `ARG` 没重新声明 |

修好后重跑即可：同名版本标签会被覆盖。不需要手工删标签——它本来就不是留档用的。

### digest 缺失

构建成功但元数据里 `image_digest` 是 `unknown`：脚本用 `imagetools inspect "${IMAGE}:${STAMP}" --format '{{.Manifest.Digest}}'` 取 index digest，拿不到就写 `unknown`（没有第二套解析路径）。

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:3.25.1 --format '{{.Manifest.Digest}}'
```

无输出的常见原因有两个：这个 tag 在制品库里还不可读（刚推送完的传播延迟，隔几秒重试）；或者 `STAMP` 与制品库里的 标签名对不上——标签就是 alpine 版本号、不带日期，`3.25` 与 `3.25.1` 是两个不同的名字。先按制品库实际标签核对，再重复上面的命令。

`base_digest` 单独是 `unknown` 时不影响构建：脚本解析基座 digest 失败（例如 `imagetools inspect alpine:latest` 没输出）就回落成 `unknown`，产物照常推送，只是这一次没法回查基座。补查方式：

```bash
# 当天 latest 的 digest（只在「构建当天」等于历史值）
docker buildx imagetools inspect alpine:latest --format '{{.Manifest.Digest}}'
# 若 version 入参本身就带 digest，base_digest 会与它一致——这是预期，不是 bug
docker buildx imagetools inspect alpine:3.25.1@sha256:<64hex> --format '{{.Manifest.Digest}}'
```

## 元数据与徽章

### 徽章灰色或 `unknown`

三个原因按概率排：

1. annotation 步骤没执行。构建在某一步 `exit 1`，写入元数据的 `cnbcool/annotations` 阶段根本没跑。
2. key 拼写不一致。可写入的 key 只有 `image_digest`、`image_digest_short`、`image_version`、`alpine_version`、`base_image`、`base_digest`、`image_size`、`image_size_arm64`、`built_at`、`source_date` 十个。
3. 看的是另一条 commit。徽章里的 `latest` 指默认分支最近一次构建，不是「最近一次手动构建」。

```bash
# 核对脚本真正写出的 key
grep -n 'image_\|alpine_version\|base_image\|base_digest\|built_at\|source_date' .cnb/scripts/build-alpine.sh | tail -16
```

### 体积显示 `unknown`

体积是按单平台镜像清单里的层求和，多架构 index 没有可加总的「总拉取体积」。脚本内部若取到的不是镜像清单，会返回 `-1` 并打一行警告，写成元数据时回落成 `unknown`。

先确认取到的是什么。直接对多架构标签取 `--raw`，拿到的是 index，没有 `layers` 字段：

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest --raw | head -5
```

正确做法是从 index 里取出该平台镜像清单的 digest，再对 digest 取原文：

```bash
STAMP=3.25.1
PLATFORM_DIGEST=$(docker buildx imagetools inspect "docker.cnb.cool/dtapp/alpine:${STAMP}" --format \
  '{{range .Manifest.Manifests}}{{if and (eq .Platform.OS "linux") (eq .Platform.Architecture "amd64")}}{{.Digest}}{{end}}{{end}}')
docker buildx imagetools inspect "docker.cnb.cool/dtapp/alpine@${PLATFORM_DIGEST}" --raw | head -5
```

输出里有 `layers` 就说明取对了；没有、或求和小于 1MB（正常 Alpine 镜像不可能这么小），再去检查 index 里是否真有 `linux/amd64` 条目、以及 `-linux-amd64` 派生标签的 digest 是否与它一致。脚本在这种情况下宁可记 `unknown`， 也不会去猜一个数字，所以徽章上的 `unknown` 本身就是「这次统计失败」的信号。

## 容器内

### 时区不对

```bash
docker run --rm docker.cnb.cool/dtapp/alpine:latest sh -c 'date; cat /etc/timezone; ls -l /etc/localtime'
```

期望 `date` 显示 `CST`、`/etc/timezone` 为 `Asia/Shanghai`、`/etc/localtime` 指向 `/usr/share/zoneinfo/Asia/Shanghai`。派生镜像里常见三种破坏方式：删了 `tzdata`、覆盖了 `/etc/localtime`、在 `docker run` 时传了别的 `TZ`。基础镜像本身没问题的话，先查派生镜像的清理步骤。

### 格式化工具缺失

```bash
command -v yamlfmt markdownfmt shfmt dockerfmt
brew install shfmt yamlfmt markdownfmt dockerfmt
```

缺哪个装哪个；`shfmt` 与 `yamlfmt` 也可以 `go install`，具体来源见 [格式化](formatting.md)。注意 `markdownfmt` 与 `dockerfmt` 没有 `--version` 参数，用 `command -v` 判断是否存在即可。

## 按钮与事件

### 按钮不存在或点了没反应

按钮定义与流水线监听是两处配置，靠事件名逐字对上：

```bash
grep -n 'event:' .cnb/web_trigger.yml
grep -rn 'web_trigger_' .cnb/workflows/ .cnb.yml
```

当前可用的事件名是 `web_trigger_build_alpine` 与 `web_trigger_codewiki`。三处必须联动：workflow 里的触发键、`.cnb/web_trigger.yml` 的 `event`、`.cnb.yml` 的 `include` 列表。漏掉 `include` 时按钮存在但没人监听，表现为点下去没有任何构建记录。

## PR 门禁

### PR 被 SCA 拦住

`.cnb/workflows/sca.yml` 的 `pull_request.target` 给漏洞扫描与 License 扫描都设了 `failOnSeverity: high`，high 及以上即让流水线失败。这是唯一的硬门禁，先确认拦你的是哪一类：

```bash
# 本次改动是否碰了包的声明
git diff --stat -- .cnb/docker/Dockerfile.alpine
```

处置分三种：升级到已修复版本（换包或换基础 `version`）；确认是上游尚未修复的 CVE，那它不该在这个 PR 里解决，按 [安全基线](security-baseline.md) 的链条等上游；确认是误报后再动扫描配置。不要为了过门禁注释掉 `failOnSeverity`——push 侧的全量报告会失去对照基线。

### AI 评审只评论不阻断

`fail_on_critical: false` 是刻意设置：评审输出建议，阻断权在 SCA。想让它更安静就调 `exclude_categories` 或 `min_severity`，不要靠忽略评论来「通过」检查。

## 相关文档

- [CI 流水线](ci-pipeline.md)
- [构建](build.md)
- [构建元数据](metadata-and-badges.md)
- [维护手册](maintenance.md)
