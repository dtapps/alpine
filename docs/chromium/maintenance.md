# 维护手册

> 补丁节奏等于上游 Alpine 的节奏：定时构建负责「跟随 Chromium 与渲染依赖的更新」，手动按钮负责「定点重出某个 Alpine 版本」，需要人判断的只有升级大版本、验证渲染没退化、同步文档和清理标签。

## 谁在什么时候动这个镜像

| 触发方式                              | 频率                          | `version` 取值                                | 产物                                               |
|---------------------------------------|-------------------------------|-----------------------------------------------|----------------------------------------------------|
| 定时构建 `crontab: 30 1 * * *`        | 每天 `01:30`（Asia/Shanghai） | 固定 `latest`                                 | 3 个变体的 `latest*` 一族，共 9 个标签位           |
| 手动按钮 `web_trigger_build_chromium` | 按需                          | 留空按 `latest`，可填 `3.24` 这类 Alpine 版本 | 上述 9 个 `latest*`，外加 `<version>*` 一族的 9 个 |

定时任务刻意不打版本标签：版本号应由人决定，否则每天一次的构建会不断覆盖历史版本标签。定时任务与手动按钮跑的是同一份 `.cnb/scripts/build-chromium.sh`，差别只在 `version`。

`version` 是 **Alpine 版本**（构建参数 `ALPINE_VERSION`），不是 Chromium 版本。Chromium 版本由该 Alpine 版本对应的软件包仓库决定，换了 Alpine 版本才会换 Chromium 大版本。脚本会先校验入参：只接受 `latest` 或 `3.24` / `3.24.3` 这类版本号，其它直接 `exit 1`（填 Chromium 版本号是最常见的错法）。

每次构建产出三个变体，都在同一条流水线里依次完成：default、`-cjk`（`WITH_CJK=1`，装 `font-noto-cjk`）、`-headless`（独立文件 `Dockerfile.headless`，内置默认启动参数 + `tini`）。`-headless` 基于同一批次 default 镜像的 digest 叠加，所以三者内容同源；变更的完整说明见 [镜像与标签](images-and-tags.md)。

## 日常补丁节奏

`Dockerfile` 不锁包版本，但装包层是带 registry 缓存的：脚本用 `--cache-from/--cache-to type=registry` 复用上一轮的层。缓存键不变，`apk add` 那一层就永远命中缓存，上游补丁再也进不到镜像里——所以脚本给装包层留了一个**缓存击穿点** `CACHE_BUST`，取当天日期（`$(date -u +%Y%m%d)`）。CI 每天用新的 `CACHE_BUST` 击穿装包层缓存，重新解析并装上当天仓库里的版本：`chromium` 与它自动带入的 9 个渲染依赖（`glib`、`pango`、`gdk-pixbuf`、`gtk+3.0`、`nss`、`freetype`、`harfbuzz`、`libstdc++`、`fontconfig`），以及显式声明的 `ca-certificates`、`font-freefont`、`tzdata`、`tini`。

为什么必须这么做：没有这个每日变化的键，registry 缓存命中后装包层直接复用，即使上游发了补丁也永远拿不到，而且现象很隐蔽——构建全绿、`chromium_built_at` 一直在更新，但 `chromium_image_digest_short` 和包版本一动不动。`CACHE_BUST` 只作用于装包层，改 `Dockerfile` 其它部分不会连带重装 Chromium；本地构建不传它也完全正确，只是失去跨轮次缓存复用。

```bash
# 有 docker CLI 的机器上确认当前 latest 指向的 digest
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:latest --format '{{.Manifest.Digest}}'
```

判断「这次构建是否真的产出了新镜像」看 commit 元数据：`chromium_built_at` 应更新，`chromium_image_digest_short` 通常会变化。若连续两天没变，说明上游没有更新，或构建在更早阶段失败了（徽章与元数据说明见 [构建元数据](metadata-and-badges.md)）。

判断「浏览器版本有没有换」不必进容器：元数据里的 `chromium_version` 就是构建期从 `chromium --version` 解析出来的实际版本，和 `chromium_image_digest`、`chromium_built_at` 一起写进 commit 元数据。标签只固定 Alpine 版本，同一个标签里的 Chromium 会随上游补丁漂移，所以「这个 digest 里是哪个浏览器」只能看它。想亲自复核再跑：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest chromium --version
```

Chromium 包体积大、更新频繁，`chromium --version` 在小版本之间也可能变；它变了不代表镜像有问题，反而说明跟随生效了。

## 手动重建版本标签

先确认 Alpine 上存在要填的 tag，有 Manifest 输出即存在：

```bash
docker buildx imagetools inspect alpine:3.24
```

然后在仓库页面 → 流水线 → 点击「打包 Chromium 镜像（多架构 amd64 + arm64）」，`version` 填 `3.24`。这一次构建做四件事：

1. 清理 `version`（去掉空白与不可打印字符，空值回落为 `latest`，非法值直接 `exit 1`）。
2. 一次多架构构建（linux/amd64 + linux/arm64）产出 manifest list，再依次叠出 `-cjk` 与 `-headless` 两个变体。
3. 标签恒定包含 `latest*` 一族；非 `latest` 时追加 `<version>`、`<version>-cjk`、`<version>-headless` 三个多架构标签。
4. 最后从 manifest list 里取各架构的镜像清单 digest，用 `docker buildx imagetools create` 打单平台标签，不再重复构建。

必须知道的副作用：标签恒定包含 `latest*` 一族，所以任何一次手动构建都会把 `latest` 一起移到本次版本上。用 `3.24` 手动重建后，`latest` 也会变成基于 `alpine:3.24` 的镜像；第二天 `01:30` 的定时构建会把它拉回上游最新（定时任务传 `version=latest`）。要长期停留在某个 minor，就别依赖 `latest`，让下游按版本标签或 digest 拉。

## 升级 Alpine 版本

### 小版本升级（3.24.2 → 3.24.3）

不需要改任何文件。`Dockerfile` 用 `cut -d'.' -f1,2 /etc/alpine-release` 推导源路径，新补丁版本自带同样的 `v3.24` 路径，源列表不用动。动作只有一次重建：`latest` 等定时构建，版本标签手动点按钮。

`Dockerfile` 里 `ARG ALPINE_VERSION` 的默认值钉的是补丁版本（当前 `3.24.3`），只有 CI 传 `version=latest` 时才会用 `alpine:latest`。本地想复现线上行为，构建时显式传 `--build-arg ALPINE_VERSION=latest`。

小版本升级同样会换掉 `chromium` 包版本。多数时候主版本不动，但偶尔会跨过主版本：这时构建会在 `EXPECTED_CHROMIUM_MAJOR` 的断言处**显式失败**并打印实际版本，按提示复核渲染后更新默认值即可，不要直接把断言删掉。

### 大版本升级（3.24 → 3.25）

按顺序走完九步，任何一步失败就停下，不要带着半套改动提交。

**第一步：确认 Docker Hub 上的 tag 存在。** 不存在会在 `FROM` 阶段失败，报拉不到 `alpine:3.25`。

```bash
docker buildx imagetools inspect alpine:3.25
```

**第二步：确认新版本的源路径可用。** `Dockerfile` 把 `major.minor` 拼成 `vX.Y` 写进 `/etc/apk/repositories`，最终是四行：cernet 的 `main` / `community`，加官方 `dl-cdn` 的 `main` / `community` 兜底。镜像站同步滞后时 `apk add` 会 404 或超时；`main` 与 `community` 两组缺任何一组都可能让某个 Chromium 依赖装不上。

**第三步：确认 6 个包在新版本仓库里仍然可用。** Chromium 及其渲染依赖在大版本间调整过仓库归属，先用 `--simulate` 试解析，不下载几百 MB（`apk add --simulate` 自己拉索引，没有单独的 `apk update` 步骤）：

```bash
docker run --rm alpine:3.25 sh -c \
  'apk add --no-cache --simulate \
     chromium ca-certificates font-freefont fontconfig tzdata tini'
```

任何一行解析失败（通常是 `unavailable`）都说明包名或仓库变了，此时不要继续构建，先确认新版本里的替代包名。

**第四步：本地构建。** 第一次跨分支构建建议先用 `EXPECTED_CHROMIUM_MAJOR=any` 跳过版本断言，等看清实际版本后再回填，否则会在下载完几百 MB 包之后才失败：

```bash
docker build -f .cnb/docker/Dockerfile.chromium \
  --build-arg ALPINE_VERSION=3.25 \
  --build-arg EXPECTED_CHROMIUM_MAJOR=any \
  -t alpine-chromium:local .
```

**第五步：跑容器自检。**

```bash
docker run --rm alpine-chromium:local sh -c \
  'cat /etc/alpine-release; chromium --version; date; cat /etc/timezone; cat /etc/apk/repositories'
```

**第六步：逐项核对验证清单。**

| 检查项     | 命令                                                                              | 期望                                                                          |
|------------|-----------------------------------------------------------------------------------|-------------------------------------------------------------------------------|
| 基础版本   | `cat /etc/alpine-release`                                                         | 新版本号，与 `version` 入参一致                                               |
| 浏览器     | `chromium --version`                                                              | 输出 `Chromium 1xx.x.x.x`；记下主版本，第七步要写进 `EXPECTED_CHROMIUM_MAJOR` |
| 渲染冒烟   | `chromium --headless --no-sandbox --disable-dev-shm-usage --dump-dom about:blank` | 输出一段 `<html>…</html>`，无 sandbox / shm 相关报错                          |
| 中文字体   | `fc-list :lang=zh`                                                                | 默认镜像应为空；用 `WITH_CJK=1` 构建后应有 Noto CJK 输出                      |
| 时区       | `date`、`cat /etc/timezone`                                                       | 显示 `CST`，时区文件为 `Asia/Shanghai`                                        |
| 源路径     | `cat /etc/apk/repositories`                                                       | 四行全是 `vX.Y`：cernet `main`/`community` + 官方源兜底                       |
| 包策略     | 对 6 个包跑 `apk policy`                                                          | 每个包都有版本与来源仓库，无 `unavailable`                                    |
| 用户与目录 | `id chrome`、`ls -ld /work`                                                       | UID/GID `10001` 存在，`/work` 属主为 `chrome:chrome`                          |
| 时区链接   | `ls -l /etc/localtime`                                                            | 指向 `/usr/share/zoneinfo/Asia/Shanghai`                                      |

渲染冒烟建议给足共享内存，否则 `--dump-dom` 也可能因 `/dev/shm` 太小而失败，误判成新版本有问题：

```bash
docker run --rm --shm-size=1g alpine-chromium:local \
  chromium --headless --no-sandbox --disable-dev-shm-usage \
  --dump-dom about:blank
```

**第七步：把新版本写回 `Dockerfile` 的两个默认值。** 两个 `ARG` 都要动，否则下一次构建会红或悄悄跑偏：

- `ARG ALPINE_VERSION`（当前 `3.24.3`）改成新的补丁版本，例如 `3.25.0`。
- `ARG EXPECTED_CHROMIUM_MAJOR`（当前 `155`，对应 Alpine 3.24 仓库里的 `155.0.x`）改成新分支里的 Chromium 主版本。它是「上游升主版本就让构建显式失败」的断言：值不跟着改，下次构建必然失败；值乱改，就等于把这层保护拆了。传 `any` 可以跳过断言，那是逃生阀——定时任务某天突然变红，通常就是上游换了主版本，按报错里的实际版本提示更新才是正解。

**第八步：同步文档。** `README.md` 里以旧版本为例的拉取与构建示例、`SECURITY.md` 的支持范围、`docs/` 里出现版本号的示例（含本册的 `3.24` / `3.24.3` / `155`），都要跟着改。文档落后于镜像比没有文档更容易误导。

**第九步：触发正式构建。** 按需选定时或按钮；用按钮时 `version` 填新版本号，会同时产出 `latest*` 与 `<version>*` 两族标签。

## 何时必须重建

| 场景                                                                                      | 是否重建 | 说明                                                                      |
|-------------------------------------------------------------------------------------------|----------|---------------------------------------------------------------------------|
| 上游 Alpine 发布新的 `chromium` 或渲染依赖包                                              | 是       | 次日定时构建靠新的 `CACHE_BUST` 击穿缓存，`latest` 自动跟随；版本标签手动 |
| `chromium` 包（或其依赖 `nss`、`freetype`、`gtk+3.0`）有 high / critical CVE 且上游已修复 | 是       | 重建后 digest 变化即代表修复进入镜像；不要等定时任务                      |
| SCA 报出其它 high / critical 且上游已修复                                                 | 是       | 同上，判断依据是上游包版本而不是漏洞披露时间                              |
| 改了 `Dockerfile`、`Dockerfile.headless`、`build-chromium.sh`、workflow                   | 是       | 构建内容或构建逻辑变了，产物必须重出                                      |
| 只改文档、只改 `.scanignore`                                                              | 否       | 不影响镜像内容，扫描与知识库各自会重跑                                    |

`chromium` 是最容易出现「上游已修、镜像未跟」的包，因为它更新频繁且漏洞披露密度高。处理顺序永远是「确认上游包版本 → 重建」，本仓库没有独立的 Chromium 修复动作。

## 历史镜像不回溯

旧 digest 不会被补丁：上游修了也只作用于之后的新构建。因此下游不要长期钉住某个 digest，而是把它当「我知道自己在用哪一份」的凭据。

不回溯的理由很实际：回溯要给历史 commit 逐个重跑构建并重新推同名 tag，等于把已经前移的 `latest` 语义再改一次，而遗留的旧产物又没有人拉。收益与成本不成比例，所以明确写成「用完即弃」。

## 周期性检查清单

| 频率         | 检查什么                                                                    | 位置 / 命令                                   |
|--------------|-----------------------------------------------------------------------------|-----------------------------------------------|
| 每周         | 定时构建是否连续成功，`chromium_built_at` 是否在更新                        | 流水线记录、`chromium_built_at` 徽章          |
| 每周         | commit 元数据里的 `chromium_version` 是否变化（不进容器就能判断浏览器版本） | 元数据 / 徽章，需要复核时再 `docker run` 对照 |
| 每周         | SCA 报告里 high / critical 是否指向上游已修的包（优先看 `chromium`）        | 安全页的漏洞扫描报告                          |
| 每周         | `chromium_version` 变化后，渲染冒烟与中文（用 `-cjk` 变体时）是否仍通过     | 本地 `docker run` 对照                        |
| 每月         | 版本标签数量是否超出实际仍在使用的 minor                                    | 制品库 tag 列表                               |
| 每月         | `.scanignore` 两条排除是否仍然必要                                          | 扫描结果对两张图片无报错即可考虑删除          |
| 每次上游发版 | `latest` 是否已带上新补丁，`apk policy` 与渲染冒烟是否正常                  | 上面的验证清单                                |

## 制品库与标签膨胀

现在每次构建产出三个变体，每个变体各有一套多架构标签与两套单平台标签：

| 变体        | 多架构 manifest list                    | 单平台（每个架构一只）                                                          |
|-------------|-----------------------------------------|---------------------------------------------------------------------------------|
| default     | `latest`、`<version>`                   | `latest-linux-{amd64,arm64}`、`<version>-linux-{amd64,arm64}`                   |
| `-cjk`      | `latest-cjk`、`<version>-cjk`           | `latest-cjk-linux-{amd64,arm64}`、`<version>-cjk-linux-{amd64,arm64}`           |
| `-headless` | `latest-headless`、`<version>-headless` | `latest-headless-linux-{amd64,arm64}`、`<version>-headless-linux-{amd64,arm64}` |

口径：

- 定时构建（`version=latest`）：3 个多架构 + 6 个单平台 = **9 个标签，全是 `latest*`**，每天原地覆盖，不膨胀。
- 带版本的手动构建：再追加 3 个 `<version>*` 多架构 + 6 个单平台 = **9 个 `<version>*` 标签**，一次构建共 18 个标签位。所以**膨胀只来自手动输入的版本号**，每多一个版本就多 9 个 tag。

清理建议：

- 保留窗口按实际仍在使用的 minor 定，更早的版本标签在确认无下游引用后删除。
- **删标签要整族删**：一个版本号的 9 只一起删（3 个变体 ×（1 个多架构 + 2 个单平台））。只删其中一只，制品库里会留下无法解释的残留——比如 `-cjk` 的单平台标签还在、多架构标签没了——反查时更容易误判成推送失败。
- `latest*` 那 9 个不要删：删掉后到下一次构建之前下游拉不到镜像。
- 单平台标签现在直接指向该架构的镜像清单（由 `docker buildx imagetools create` 从 manifest list 里取 digest 打出来），不再是带 attestation 的 index；但语义上它与同变体的多架构标签是一族，仍然一起删、一起留。
- 删除操作在制品库页面按 tag 进行。删 tag 不等于立刻释放空间，旧 digest 的 blob 由制品库自行回收。
- Chromium 镜像每个 digest 都是数百 MB，三个变体又共用同一批基础层，标签膨胀带来的存储成本比纯 alpine 镜像明显，清理比「留着备用」更划算。

## 已知待办

| 待办               | 现状                                                                                                      | 影响                                                                                |
|--------------------|-----------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| 未接入镜像层扫描   | 只有 SCA 扫 `Dockerfile` 的依赖声明                                                                       | `chromium` 层内二进制的 CVE 不会被发现，需要下游自己加扫描                          |
| 镜像未签名         | 制品库不校验来源真实性                                                                                    | 强校验只能按 digest 固定拉取                                                        |
| 版本标签不自动跟随 | 仅手动触发                                                                                                | 落后 `latest` 的幅度取决于巡检频率                                                  |
| 中日韩字形覆盖     | 已有 `-cjk` 变体（`font-noto-cjk`，+88.8 MiB），但**默认镜像仍是 `font-freefont`**，而它不含任何 CJK 字形 | 不显式选变体，中文截图必然是豆腐块，见 [排错手册](troubleshooting.md)               |
| 无头启动参数不内置 | 已有 `-headless` 变体（内置一套默认参数 + `tini`），但**默认镜像仍不内置**                                | 用默认镜像要自己传 `-e CHROMIUM_USER_FLAGS`，忘了 `--no-sandbox` 在 root 下直接失败 |

## 相关文档

- [镜像与标签](images-and-tags.md)
- [CI 流水线](ci-pipeline.md)
- [安全基线](security-baseline.md)
- [排错手册](troubleshooting.md)
- [SECURITY](../../SECURITY.md)
