# 维护手册

> 补丁节奏等于上游 Alpine 的节奏：定时构建负责「跟随 Chromium 与渲染依赖的更新」，手动按钮负责「定点重出某个 Alpine 版本」，需要人判断的只有升级大版本、验证渲染没退化、同步文档和清理标签。Chromium 的基座是本仓库构建的 Alpine 基础镜像，所以升级时基座要先于 Chromium 产出；标签也与基座同一套 5 标签契约。

## 谁在什么时候动这个镜像

| 触发方式                              | 频率                          | `version` 取值                                | 产物                                                                         |
|---------------------------------------|-------------------------------|-----------------------------------------------|------------------------------------------------------------------------------|
| 定时构建 `crontab: 5 1 * * *`         | 每天 `01:05`（Asia/Shanghai） | 固定 `latest`                                 | 5 个标签：`<alpine 版本>`、其单平台两只、`<minor>` 与 `latest`（基座对齐时） |
| 手动按钮 `web_trigger_build_chromium` | 按需                          | 留空按 `latest`，可填 `3.24` 这类 Alpine 版本 | 同样是 5 个标签；版本号来自解析出的基座实际版本，不是入参                    |

定时任务与手动按钮跑的是同一份 `.cnb/scripts/build-chromium.sh`，差别只在 `version` 选哪个基座标签。两者产出的标签集合相同：`<alpine 版本>` 与单平台标签每次都推；`<minor>` / `latest` 只在 `dtapp/alpine:<同名标签>` 已指向本次基座 digest 时才提升，所以手动构建旧分支不会把 `latest` 拉回去。

`version` 是 **Alpine 版本**，只用来选基座标签（`latest` / `3.24` / `3.24.3`），不是 Chromium 版本。Chromium 版本由该 Alpine 版本对应的软件包仓库决定，换了 Alpine 版本才会换 Chromium 大版本。脚本会先校验入参：只接受 `latest` 或 `3.24` / `3.24.3` 这类版本号，其它直接 `exit 1`（填 Chromium 版本号是最常见的错法）。产物标签用的是从基座容器读出的实际版本，不是入参原样。

基座仓库里必须有对应标签，否则构建在解析阶段直接失败，不会退回官方 `alpine`。定时任务取的是当天 `00:05` 刷新的 `<仓库 slug>:latest`；填具体版本则要求 build-alpine 侧事先以该版本构建过。解析出实际版本后，脚本还会确认 `<仓库 slug>:<实际版本>` 存在，并钉住它的 digest 构建。

每次构建只产出一个中性镜像：一次多架构 `buildx build`，标签 `<alpine 版本>`，再从同一份 manifest list 派生两个单平台标签；冒烟与 OCI 基座标签校验通过后，按基座对齐情况提升 `<minor>` / `latest`。`-cjk` / `-headless` 的配方保留在仓库里（`WITH_CJK=1` / `Dockerfile.headless`），但 CI 不再发布；标签契约见 [镜像与标签](images-and-tags.md)。

## 日常补丁节奏

`Dockerfile` 不锁包版本。两侧都使用 registry 缓存，但装包层的缓存键里带 APK 索引指纹：索引不变就命中，任何包升级索引就变、`apk add` 重跑。装上的就是当天仓库里的版本——`chromium` 与它自动带入的 9 个渲染依赖（`glib`、`pango`、`gdk-pixbuf`、`gtk+3.0`、`nss`、`freetype`、`harfbuzz`、`libstdc++`、`fontconfig`），以及显式声明的 `ca-certificates`、`font-freefont`、`tzdata`、`tini`。

为什么必须防住「缓存命中导致不重装」：现象很隐蔽——构建全绿、`chromium_built_at` 一直在更新，但 `chromium_image_digest_short` 和包版本一动不动。索引指纹解决了这一点：只有「仓库里一个包都没变」时才命中。它只作用于装包层，改 `Dockerfile` 其它部分不会连带重装 Chromium。

基座更新是另一条传导路径：`FROM` 引用里带基座 digest，`00:05` 的基座构建一旦产出新 digest，Chromium 的 `FROM` 及下游层会自动失效，不需要索引指纹参与。两条路径互补——基座补丁靠 digest，上游 chromium/runtime 补丁靠「索引变化 → 重装」。

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

## 手动触发一次构建（可指定基座分支）

先确认本仓库的基座里有要填的标签，有 Manifest 输出即存在：

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:3.24
```

基座侧没有这个标签时，先用「打包 Alpine 镜像」按钮以相同 `version` 跑一次基座流水线；Chromium 这边不会再退回官方 `alpine`。

然后在仓库页面 → 流水线 → 点击「打包 Chromium 镜像（多架构 amd64 + arm64）」，`version` 填 `3.24`。这一次构建做五件事：

1. 清理 `version`（去掉空白与不可打印字符，空值回落为 `latest`，非法值直接 `exit 1`）。
2. 按 `version` 选基座标签，进容器读 `/etc/alpine-release` 得到实际版本（如 `3.24.3`），确认 `<仓库 slug>:3.24.3` 存在并取它的 digest，取不到直接失败。
3. 一次多架构构建（linux/amd64 + linux/arm64）产出 manifest list，推 `<alpine 版本>`。
4. 从 manifest list 里取各架构的镜像清单 digest，用 `docker buildx imagetools create` 打两个单平台标签，不重复构建。
5. 冒烟与 OCI 基座标签校验通过后，按基座对齐情况提升 `<minor>` / `latest`。

必须知道的点：手动构建旧分支（如基座 `latest` 还在 3.25、你填 `version=3.24`）时，`<minor>` / `latest` 会因为基座尚未对齐而被跳过，Chromium 不会跑到基座前面。要长期停留在某个 minor，让下游按 `<major.minor>` 或 digest 拉。

## 升级 Alpine 版本

### 小版本升级（3.24.2 → 3.24.3）

不需要改任何文件。`Dockerfile` 用 `cut -d'.' -f1,2 /etc/alpine-release` 推导源路径，新补丁版本自带同样的 `v3.24` 路径，源列表不用动。动作只有一次重建：次日 `01:05` 定时任务会产出新的 `<alpine 版本>` 与单平台标签，基座对齐后同时刷新 `<minor>` / `latest`；想立刻拿到就手动点按钮。

`Dockerfile` 里 `ARG ALPINE_VERSION` 的默认值是 `latest`，CI 定时任务也传 `version=latest`，行为一致：解析的都是基座 `<仓库 slug>:latest`，而基座本身每天 `00:05` 重建，补丁自动传导。要钉住某个补丁版本做复现或审计时，显式传 `version=3.24.3`，此时基座仓库里得有 `3.24.3` 这个标签（用 build-alpine 按钮以同一版本构建过）。

小版本升级同样会换掉 `chromium` 包版本。多数时候主版本不动；如果你填了 `EXPECTED_CHROMIUM_MAJOR` 断言，偶尔跨主版本时构建会在断言处**显式失败**并打印实际版本，按提示复核渲染后更新断言即可，不要直接把断言删掉。定时任务不传该值，默认不校验。

### 大版本升级（3.24 → 3.25）

按顺序走完九步，任何一步失败就停下，不要带着半套改动提交。

**第一步：先产出并确认基座标签。** Chromium 不再 `FROM alpine:3.25`，而是 `FROM <仓库 slug>:3.25@<digest>`。基座里没有这个标签时，脚本在解析阶段就会失败，不会走到 `FROM`。所以先用「打包 Alpine 镜像」按钮以 `version=3.25` 构建基座，再确认标签存在：

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:3.25
```

只想先独立验证 Chromium 的 Dockerfile 时，可以本地不传 `CHROMIUM_BASE_IMAGE`，基座落到官方 `alpine:3.25`；但正式构建必须等基座标签就位。

**第二步：确认新版本的源路径可用。** CNB 侧 `Dockerfile` 只把基座源的主机名替换为腾讯云，`vX.Y` 路径由基座镜像自带，最终是腾讯云的 `main` + `community` 两行；GitHub 侧沿用官方源的两行，不做覆写。源站同步滞后时 `apk add` 会 404 或超时；`main` 与 `community` 两组缺任何一组都可能让某个 Chromium 依赖装不上。

**第三步：确认 6 个包在新版本仓库里仍然可用。** Chromium 及其渲染依赖在大版本间调整过仓库归属，先用 `--simulate` 试解析，不下载几百 MB（`apk add --simulate` 自己拉索引，没有单独的 `apk update` 步骤）：

```bash
docker run --rm alpine:3.25 sh -c \
  'apk add --no-cache --simulate \
     chromium ca-certificates font-freefont fontconfig tzdata tini'
```

任何一行解析失败（通常是 `unavailable`）都说明包名或仓库变了，此时不要继续构建，先确认新版本里的替代包名。

**第四步：本地构建。** 第一次跨分支构建建议先用 `EXPECTED_CHROMIUM_MAJOR=any` 跳过版本断言，等看清实际版本后再回填，否则会在下载完几百 MB 包之后才失败。下面这条不传 `CHROMIUM_BASE_IMAGE`，基座是官方 `alpine:3.25`，用于独立确认 Dockerfile 本身没问题：

```bash
docker build -f .cnb/docker/Dockerfile.chromium \
  --build-arg ALPINE_VERSION=3.25 \
  --build-arg EXPECTED_CHROMIUM_MAJOR=any \
  -t alpine-chromium:local .
```

要连基座一起验（接近 CI 的真实形态），先按第一步产出并拉到基座，再显式传入：

```bash
docker build -f .cnb/docker/Dockerfile.chromium \
  --build-arg CHROMIUM_BASE_IMAGE=docker.cnb.cool/dtapp/alpine:3.25 \
  --build-arg CHROMIUM_BASE_NAME=docker.cnb.cool/dtapp/alpine:3.25 \
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
| 源路径     | `cat /etc/apk/repositories`                                                       | CNB：腾讯云 `main`/`community` 两行；GitHub：官方源两行                       |
| 包策略     | 对 6 个包跑 `apk policy`                                                          | 每个包都有版本与来源仓库，无 `unavailable`                                    |
| 用户与目录 | `id chrome`、`ls -ld /work`                                                       | UID/GID `10001` 存在，`/work` 属主为 `chrome:chrome`                          |
| 时区链接   | `ls -l /etc/localtime`                                                            | 指向 `/usr/share/zoneinfo/Asia/Shanghai`                                      |

渲染冒烟建议给足共享内存，否则 `--dump-dom` 也可能因 `/dev/shm` 太小而失败，误判成新版本有问题：

```bash
docker run --rm --shm-size=1g alpine-chromium:local \
  chromium --headless --no-sandbox --disable-dev-shm-usage \
  --dump-dom about:blank
```

**第七步：确认 `Dockerfile` 的默认值。** 默认为空/`latest` 的项不要去「回填」，只处理真正需要钉死的：

- `ARG ALPINE_VERSION` 默认 `latest`，解析的是基座 `<仓库 slug>:latest`，跟随基座每天重建，大版本升级通常不用改；只有希望默认构建钉在某个分支或补丁上时才改（例如 `3.25`），并把 `<仓库 slug>:3.25` 的基座先产出。
- `ARG EXPECTED_CHROMIUM_MAJOR` 默认空 = 不校验。要主动盯某个分支的 Chromium 主版本时，填新分支里的主版本（如 `156`）。它是「上游升主版本就让构建显式失败」的断言：值不跟着改，下次构建必然失败；值乱改，就等于把这层保护拆了。传 `any` 可以跳过断言，那是逃生阀。

**第八步：同步文档。** `README.md` 里以旧版本为例的拉取与构建示例、`SECURITY.md` 的支持范围、`docs/` 里出现版本号的示例（含本册的 `3.24` / `3.24.3` / `155`），都要跟着改。文档落后于镜像比没有文档更容易误导。

**第九步：触发正式构建。** 按需选定时或按钮；用按钮时 `version` 填新版本号（如 `3.25`），产物标签仍是解析出的实际版本（如 `3.25.1`）加单平台标签；`<minor>` / `latest` 只在基座同名标签对齐后提升。

## 何时必须重建

| 场景                                                                                      | 是否重建 | 说明                                                      |
|-------------------------------------------------------------------------------------------|----------|-----------------------------------------------------------|
| 上游 Alpine 发布新的 `chromium` 或渲染依赖包                                              | 是       | 次日定时构建重新装包，`latest` 自动跟随；版本标签每次都推 |
| `chromium` 包（或其依赖 `nss`、`freetype`、`gtk+3.0`）有 high / critical CVE 且上游已修复 | 是       | 重建后 digest 变化即代表修复进入镜像；不要等定时任务      |
| SCA 报出其它 high / critical 且上游已修复                                                 | 是       | 同上，判断依据是上游包版本而不是漏洞披露时间              |
| 改了 `Dockerfile`、`Dockerfile.headless`、`build-chromium.sh`、workflow                   | 是       | 构建内容或构建逻辑变了，产物必须重出                      |
| 只改文档、只改 `.scanignore`                                                              | 否       | 不影响镜像内容，扫描与知识库各自会重跑                    |

`chromium` 是最容易出现「上游已修、镜像未跟」的包，因为它更新频繁且漏洞披露密度高。处理顺序永远是「确认上游包版本 → 重建」，本仓库没有独立的 Chromium 修复动作。

## 历史镜像不回溯

旧 digest 不会被补丁：上游修了也只作用于之后的新构建。因此下游不要长期钉住某个 digest，而是把它当「我知道自己在用哪一份」的凭据。

不回溯的理由很实际：回溯要给历史 commit 逐个重跑构建并重新推同名 tag，等于把已经前移的 `latest` 语义再改一次，而遗留的旧产物又没有人拉。收益与成本不成比例，所以明确写成「用完即弃」。

## 周期性检查清单

| 频率         | 检查什么                                                                        | 位置 / 命令                                   |
|--------------|---------------------------------------------------------------------------------|-----------------------------------------------|
| 每周         | 定时构建是否连续成功，`chromium_built_at` 是否在更新                            | 流水线记录、`chromium_built_at` 徽章          |
| 每周         | 基座流水线（`00:05`）是否成功、`<仓库 slug>:latest` 的 digest 是否在动          | 基座流水线记录、`chromium_base_digest` 元数据 |
| 每周         | commit 元数据里的 `chromium_version` 是否变化（不进容器就能判断浏览器版本）     | 元数据 / 徽章，需要复核时再 `docker run` 对照 |
| 每周         | SCA 报告里 high / critical 是否指向上游已修的包（优先看 `chromium`）            | 安全页的漏洞扫描报告                          |
| 每周         | `chromium_version` 变化后，渲染冒烟与中文（自建 `WITH_CJK=1` 镜像时）是否仍通过 | 本地 `docker run` 对照                        |
| 每月         | 制品库是否只剩预期标签（5 个/次构建，旧名已清理）                               | 制品库 tag 列表                               |
| 每月         | `.scanignore` 两条排除是否仍然必要                                              | 扫描结果对两张图片无报错即可考虑删除          |
| 每次上游发版 | `latest` 是否已带上新补丁，`apk policy` 与渲染冒烟是否正常                      | 上面的验证清单                                |

## 制品库与标签膨胀

现在每次构建只产出 5 个标签，与 Alpine 基座同一套契约：

| 标签                         | 类型                       | 何时出现                     |
|------------------------------|----------------------------|------------------------------|
| `<alpine 版本>`，如 `3.24.3` | 多架构 manifest list       | 每次构建                     |
| `<alpine 版本>-linux-amd64`  | 单平台（从上面的清单派生） | 每次构建                     |
| `<alpine 版本>-linux-arm64`  | 单平台（同上）             | 每次构建                     |
| `<major.minor>`，如 `3.24`   | 多架构，滚动               | 冒烟通过且基座同名标签已对齐 |
| `latest`                     | 多架构，滚动               | 同上                         |

口径：

- 一次构建最多新增 5 个标签位；同名标签每天被覆盖，不按日期膨胀。
- **膨胀只来自新的 Alpine 补丁版本**：上游每发一个 `3.24.x`，就多一组 3 个标签（版本 + 两个单平台），旧的 `3.24.y` 会留在制品库里。

清理建议：

- 保留窗口按实际仍在使用的 minor 定，更早的补丁版本标签在确认无下游引用后删除。
- **同一个版本号的 3 只一起删**（`<版本>`、`<版本>-linux-amd64`、`<版本>-linux-arm64`），只删其中一只会留下无法解释的残留。
- `<major.minor>` 与 `latest` 不要删：删掉后到下一次构建之前下游拉不到镜像。
- 单平台标签直接指向该架构的镜像清单（由 `docker buildx imagetools create` 从 manifest list 里取 digest 打出来），不是带 attestation 的 index。
- 删除操作在制品库页面按 tag 进行。删 tag 不等于立刻释放空间，旧 digest 的 blob 由制品库自行回收。
- Chromium 镜像每个 digest 都是数百 MB，清理比「留着备用」更划算。

## 已知待办

| 待办                 | 现状                                                                                                 | 影响                                                                            |
|----------------------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------|
| 未接入镜像层扫描     | 只有 SCA 扫 `Dockerfile` 的依赖声明                                                                  | `chromium` 层内二进制的 CVE 不会被发现，需要下游自己加扫描                      |
| 镜像未签名           | 制品库不校验来源真实性                                                                               | 强校验只能按 digest 固定拉取                                                    |
| 旧补丁版本标签会累积 | 每次构建都推 `<alpine 版本>`；旧版本不会自动删除                                                     | 需要按保留窗口手工清理，见上文「制品库与标签膨胀」                              |
| 中日韩字形覆盖       | 默认镜像用 `font-freefont`，不含任何 CJK 字形；CI 不再发布 `-cjk` 变体，需要时自行 `WITH_CJK=1` 构建 | 不自行构建带字体的镜像，中文截图必然是豆腐块，见 [排错手册](troubleshooting.md) |
| 无头启动参数不内置   | 默认镜像不内置；`Dockerfile.headless` 配方保留，CI 不发布                                            | 要自己传 `-e CHROMIUM_USER_FLAGS`，忘了 `--no-sandbox` 在 root 下直接失败       |

## 相关文档

- [镜像与标签](images-and-tags.md)
- [CI 流水线](ci-pipeline.md)
- [安全基线](security-baseline.md)
- [排错手册](troubleshooting.md)
- [SECURITY](../../SECURITY.md)
