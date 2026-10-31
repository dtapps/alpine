# 排错手册

> 按症状查：先在总表里定位到主题与对应文档，再跳到本册对应小节复制命令；每条都给出原因、可执行处置和延伸阅读。本页出现频率最高的不是流水线，而是无头 Chromium 的启动参数、沙箱与 `/dev/shm`。

## 症状总表

| 症状                                                             | 可能原因                                                                      | 处置                                                                          | 对应文档                             |
|------------------------------------------------------------------|-------------------------------------------------------------------------------|-------------------------------------------------------------------------------|--------------------------------------|
| `FROM` 阶段拉不到基础镜像                                        | 基座引用无效：CI 里基座标签不存在，本地则是 alpine tag 不存在或网络不通       | 先跑 build-alpine 产出基座，或本地换真实存在的 alpine tag                     | [构建](build.md)                     |
| `apk add` 超时或 404                                             | 镜像站未同步新 minor、源站故障、基座源主机不是你预期的那个                    | CNB 检查 `sed` 目标主机，GitHub 检查官方源连通性                              | [APK 源与网络](mirrors.md)           |
| buildx 报 bootstrap 失败                                         | 自建了 `docker-container` builder                                             | 删掉自建 builder，用 CNB 内置 builder                                         | [构建](build.md)                     |
| push 返回 401 / 403                                              | token 缺失或过期 / 无该仓库写权限                                             | 核对 `imports` 与 registry 地址                                               | [CI 流水线](ci-pipeline.md)          |
| 元数据里 digest 是 `unknown`                                     | 取不到 manifest digest，或元数据步骤没跑                                      | 手动 `imagetools inspect` 复核                                                | [构建元数据](metadata-and-badges.md) |
| 徽章灰色或显示 `unknown`                                         | key 拼错、annotation 未写入、看错 commit                                      | 对照元数据 key 与写入步骤                                                     | [构建元数据](metadata-and-badges.md) |
| 体积显示 `unknown`                                               | 取到的对象里没有 `layers` 字段（拿到的是 index）                              | 按平台清单 digest 再取 `--raw`                                                | [构建元数据](metadata-and-badges.md) |
| 单平台标签里看到的东西与预期不符                                 | 分不清 index 与镜像清单                                                       | `--raw` 里有 `layers` 才是镜像清单                                            | [镜像与标签](images-and-tags.md)     |
| `Running as root without --no-sandbox is not supported`          | 容器内是 root，Chromium 不允许 root 带沙箱启动                                | 加 `--no-sandbox`，或用自建 headless 镜像；要沙箱就 `USER chrome`             | [安全基线](security-baseline.md)     |
| `No usable sandbox!`                                             | userns 与 SUID helper 都不可用，与「是不是 root」无关                         | 加 `--no-sandbox`，或 `--cap-add=SYS_ADMIN` / 换宿主环境                      | [安全基线](security-baseline.md)     |
| 渲染进程崩溃 / 日志里出现 `/dev/shm` 相关报错                    | 容器默认 `/dev/shm` 只有 64MB，渲染写满                                       | `--shm-size=1g` + `--disable-dev-shm-usage`，或 `--tmpfs /dev/shm:rw,size=1g` | [快速上手](getting-started.md)       |
| 并发实例互相踢：`SingletonLock` / `profile appears to be in use` | root + root 属主 HOME 时包装脚本强塞 `--user-data-dir=$HOME/.config/chromium` | 每个实例显式传 `--user-data-dir=/tmp/<name>`                                  | 本册「并发实例互相踢」               |
| 截图或 PDF 是空白                                                | 页面没加载完、窗口太小、输出路径不可写                                        | 设 `--window-size`、`--virtual-time-budget`，检查退出码                       | [快速上手](getting-started.md)       |
| 中文显示成方块、页面缺字                                         | 主镜像的 `font-freefont` 完全不含 CJK 字形（实测 cmap 里码位为 0）            | 用 `WITH_CJK=1` 自建（`font-noto-cjk`，+88.8 MiB），`fc-list :lang=zh` 验证   | [Dockerfile 解析](dockerfile.md)     |
| 挂了自定义字体但页面仍缺字                                       | 挂载后没重建 fontconfig 缓存                                                  | `fc-cache -fv` 后重新 `fc-list`                                               | [Dockerfile 解析](dockerfile.md)     |
| `chromium: not found`                                            | 用了纯 alpine 基础镜像，或派生镜像删了包                                      | 换成 `docker.cnb.cool/dtapp/alpine/chromium`，核对二进制                      | [快速上手](getting-started.md)       |
| 渲染 / 截图一直不返回                                            | 页面资源挂住、容器出不了网、没有等待上限                                      | 先用 `about:blank` 区分，再给 `--virtual-time-budget`                         | [快速上手](getting-started.md)       |
| 加了 `--single-process` 后渲染进程随机崩                         | 那是调试开关，新版无头下必崩                                                  | 删掉 `--single-process` 与 `--no-zygote`                                      | 本册「先把启动参数放对位置」         |
| 派生镜像 `npm i puppeteer` 又下载了一份浏览器                    | `PUPPETEER_SKIP_DOWNLOAD=1` 被覆盖或丢失                                      | 别覆盖它；确实要官方 Chromium 时才覆盖                                        | 本册「镜像内路径与环境变量」         |
| 容器内时间是 UTC                                                 | 时区未生效，`/etc/localtime` 被覆盖或删了 tzdata                              | 检查时区文件与 `TZ` 变量                                                      | [Dockerfile 解析](dockerfile.md)     |
| 容器里找不到 `curl` / `nc` / `drill` / `git`                     | 用错了镜像，或派生镜像裁掉了基座里的工具（本镜像默认继承它们）                | 对照 `FROM`；需要 `dig` 时在派生镜像加 `bind-tools`                           | [安全基线](security-baseline.md)     |
| `make format` 报 command not found                               | 本机缺四个格式化工具之一                                                      | 按工具链文档安装                                                              | [格式化](formatting.md)              |
| 页面没有构建按钮 / 点了不触发                                    | 按钮 `event` 与 workflow 触发键不一致或未 include                             | 三处事件名对齐                                                                | [CI 流水线](ci-pipeline.md)          |
| PR 被 SCA 拦住                                                   | `failOnSeverity: high` 命中 high 及以上漏洞                                   | 升级包或确认误报，不要关掉门禁                                                | [安全基线](security-baseline.md)     |

## 构建阶段

### 找不到基座

脚本在 `FROM` 之前先解析基座 digest，失败时的报错是 `❌ 找不到基座 <仓库 slug>:<version>：先运行 build-alpine 流水线并传入相同的 version…`。它发生在构建阶段之前，说明本仓库基座仓库里没有对应标签：

- 定时任务：当天 `00:05` 的基座构建失败或还没跑完，`<仓库 slug>:latest` 不存在；
- 手动填了具体版本（`3.24` / `3.24.3`）：基座侧从未以该版本构建过，或者被清理了；
- 在 fork / 私有仓库里只跑了 Chromium 流水线，基座路径解析到你的命名空间，那里还没有产物。

```bash
# 直接确认标签与 digest
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:latest
```

处置：先用「打包 Alpine 镜像」按钮以相同 `version` 跑一次基座流水线，成功后再重跑 Chromium。Chromium 脚本不会退回官方 `alpine`，所以这一步不能跳过。

### `FROM` 拉取失败

CI 里 `FROM` 用 `CHROMIUM_BASE_IMAGE` 指向本仓库基座 `<仓库 slug>:<version>@sha256:…`，本地不传它时才落到官方 `alpine`。所以先分清场景：

```bash
# 1) CI：基座标签是否存在（不存在会先报「找不到基座」，见上一小节）
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine:3.24
# 2) 本地：官方 alpine tag 是否存在、网络是否通
docker buildx imagetools inspect alpine:3.24
# 3) 用 latest 对照：latest 也失败说明是网络/registry 不可达，而不是版本号写错
docker buildx imagetools inspect alpine:latest
```

处置：CI 里先以相同 `version` 跑一次 build-alpine，让基座标签就位；本地要么换真实存在的 alpine tag，要么显式传 `CHROMIUM_BASE_IMAGE` 指向已拉到的基座。`version` 填 `3.24`、`3.24.3` 这类 Alpine 版本号，不要写成 `v3.24`。也别忘了 `version` 是 **Alpine 版本**，填 Chromium 版本号（例如 `131`）会被 `build-chromium.sh` 直接拦下（它的校验只放行 `latest` 与 `3.24` / `3.24.3` 这类版本号）。

想构建非默认分支（例如 `3.21`）时，本地 `FROM` 能过（基座是官方 `alpine:3.21`），但紧接着会被 Dockerfile 的版本断言拦下——这仍是**预期行为**：得同时传 `--build-arg EXPECTED_CHROMIUM_MAJOR=<该分支的 chromium 主版本>`（3.21 是 136，3.22 是 142），并且清楚那个分支的 chromium 已经冻结、3.20 更是早已 EOL。CI 里还要求基座仓库已有 `3.21` 标签，否则会先停在「找不到基座」。

定时任务传的是 `version=latest`，脚本先用它选基座 `<仓库 slug>:latest`，读容器得到实际版本（如 `3.24.3`）后再传 `--build-arg ALPINE_VERSION=3.24.3`。本地不传 `CHROMIUM_BASE_IMAGE` 时基座是官方 `alpine:latest`，与 CI 的私有基座不是同一份。所以「定时任务失败、本地构建成功」时，先看 Runner 出网与基座标签，再看你本地是否钉了与 CI 不同的 `ALPINE_VERSION` / `CHROMIUM_BASE_IMAGE`。

### `apk add` 超时或 404

镜像里没有单独的 `apk update` 层，`apk add --no-cache` 自己拉索引。源路径不在本仓库手写：基座自带的 `/etc/apk/repositories` 已经是 `vX.Y` 的 `main` + `community` 两行，CNB 的 STEP 1 只用 `sed` 把主机名换成腾讯云；GitHub 侧不覆写，沿用官方源的两行。

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest \
  sh -c 'cat /etc/alpine-release; cat /etc/apk/repositories'
```

看到报错 URL 里的主机不是预期的那一个，说明换源没生效或被人为改过：CNB 侧检查 `sed` 是否命中 `dl-cdn.alpinelinux.org`，GitHub 侧检查是否有人加了换源步骤。只剩 404 而主机正确，是源站尚未同步该 minor：CNB 侧只有腾讯云一台源，没有跨站兜底，只能等同步或按变更流程临时补源；GitHub 侧是官方源。不要为了绕开 404 临时堆一堆镜像站——不同同步进度的仓库之间容易撞上依赖版本冲突。

Chromium 镜像还有一类特有表现：索引拉取通过但 `apk add` 阶段报某个依赖 `unavailable`。那是包名或仓库归属在 Alpine 新版本里变了（`chromium` 与它的图形栈属于这一类），不是网络问题，处置见 [维护手册](maintenance.md) 的「大版本升级」第三步。

### buildx bootstrap 失败

不要自建 builder。CNB 的 `services: docker` 默认已内置可做多架构的 buildx builder：

```bash
docker buildx version
docker buildx ls
docker buildx inspect
```

`build-chromium.sh` 在开始构建之前就跑这三条自检。若在受限容器里执行过 `docker buildx create --driver docker-container`，会因拉不起嵌套 buildkitd 而 bootstrap 失败：删掉该 builder，回到内置的实例，同时确认 workflow 里声明了 `services: docker`。

## 推送与制品库

### push 401 / 403

401 是认证失败，403 是认证通过但没有目标仓库的写权限。

```bash
# 变量是否注入（imports 引入的环境变量）
printf '%s\n' "${CNB_DOCKER_REGISTRY}" "${CNB_TOKEN_USER_NAME}"
# 手动复现登录（本地复现请换自己 fork 的地址）
docker login -u "${CNB_TOKEN_USER_NAME}" -p "${CNB_TOKEN}" "${CNB_DOCKER_REGISTRY}"
```

凭证来自 `imports` 里引入的组织密钥仓库，仓库内没有任何字面量。缺变量通常是 `imports` 那一行被删或路径写错；能登录但 403 则是账号对该仓库没有推送权限。不要拿线上路径 `docker.cnb.cool/dtapp/alpine/chromium` 做实验性推送——Chromium 镜像每次推送都是数百 MB，实验性推送还会把 `latest` 一起挪走。

### manifest list 与单平台标签的区别

| 标签                                       | 承诺的平台范围 | `--raw` 里看到的对象                  |
|--------------------------------------------|----------------|---------------------------------------|
| `latest`、`<major.minor>`、`<alpine 版本>` | amd64 + arm64  | 含两个平台条目的 manifest list        |
| `<版本>-linux-amd64`、`<版本>-linux-arm64` | 单一平台       | 直接指向该架构的镜像清单，含 `layers` |

单平台标签现在由 `docker buildx imagetools create` 从 manifest list 里取出该架构的 digest 直接打出来，**不再是**带 attestation 的 index：

```bash
# 有 layers 就说明拿到的是镜像清单
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:3.24.3-linux-amd64 --raw | head -5
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:latest --raw | head -5
```

第二行输出的是 index（只有平台条目，没有 `layers`），这是多架构标签的正常形态。看到 index 就以为「多架构合并失败」是常见误判；真正要小心的是拿 index 去求体积，会得到几 KB 的假值（见下文「体积显示 `unknown`」）。如果你在单平台标签里看到 index，说明那是旧产物或有人手工重推过这个 tag。

### digest 缺失

构建成功但元数据里 `chromium_image_digest` 是 `unknown`：脚本先取 `imagetools inspect` 文本输出里的 `Digest:` 行，取不到再退回 `--format` 模板，两者都空才写 `unknown`。

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:latest --format '{{.Manifest.Digest}}'
```

无输出的常见原因是推送步骤并未真正完成（前面的 `buildx build --push` 非零退出但后续步骤仍在跑），或者该 tag 在制品库里尚未可读。Chromium 镜像层大，推送耗时长，网络抖动下更容易出现「推了一半」；先确认构建阶段的退出码，再重复上面的命令。

## 元数据与徽章

### 徽章灰色或 `unknown`

三个原因按概率排：

1. annotation 步骤没执行。构建在某一步 `exit 1`，写入元数据的 `cnbcool/annotations` 阶段根本没跑。
2. key 拼写不一致。可写入的 key 只有 `chromium_image_digest`、`chromium_image_digest_short`、`chromium_image_size`、`chromium_image_size_arm64`、`chromium_base_image`、`chromium_base_digest`、`chromium_version`、`chromium_built_at`。
3. 看的是另一条 commit。徽章里的 `latest` 指默认分支最近一次构建，不是「最近一次手动构建」。

```bash
# 核对脚本真正写出的 key
grep -n 'image_\|chromium_version\|chromium_built_at' .cnb/scripts/build-chromium.sh | tail -8
```

`chromium_version` 是本期新增的：标签只固定 Alpine 版本，同一个标签里的 Chromium 会随上游补丁漂移，所以「这个 digest 里是哪个浏览器」只能看这个 key。`chromium_base_image` / `chromium_base_digest` 记录本次构建叠在哪个基座上，用来回答「这个 Chromium 镜像是从哪份 Alpine 基座出来的」。

### 体积显示 `unknown`

体积是按单平台镜像清单里的层求和，多架构 index 没有可加总的「总拉取体积」。脚本内部若取到的不是镜像清单，会返回 `-1` 并打一行警告，写成元数据时回落成 `unknown`。

先确认取到的是什么。单平台标签现在直接指向该架构的镜像清单，所以通常直接就能看到 `layers`：

```bash
docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:3.24.3-linux-amd64 --raw | head -5
```

没有 `layers` 就说明拿到的是 index（旧产物，或你误用了多架构标签），改从多架构 index 里取出该平台镜像清单的 digest，再对 digest 取原文：

```bash
PLATFORM_DIGEST=$(docker buildx imagetools inspect docker.cnb.cool/dtapp/alpine/chromium:latest --format \
  '{{range .Manifest.Manifests}}{{if and (eq .Platform.OS "linux") (eq .Platform.Architecture "amd64")}}{{.Digest}}{{end}}{{end}}')
docker buildx imagetools inspect "docker.cnb.cool/dtapp/alpine/chromium@${PLATFORM_DIGEST}" --raw | head -5
```

输出里有 `layers` 就说明取对了；没有、或求和小于 1MB（本镜像数百 MB 量级，低于 1MB 必然取错了对象），再去检查单平台标签是否推送成功。

## 容器内：无头浏览器

这一节是本镜像最高频的问题来源。所有示例都假设容器内以 root 运行（这也是默认值），镜像取自 `docker.cnb.cool/dtapp/alpine/chromium:latest`。

### 先把启动参数放对位置

基础镜像刻意不内置任何启动参数：`--no-sandbox` 取决于你是不是 root，`--disable-dev-shm-usage` 取决于 `/dev/shm` 多大，写进 `ENTRYPOINT` 等于替所有下游决定启动参数（[CONTRIBUTING](../../CONTRIBUTING.md) 的硬性规则）。三种落地方式：

| 方式                                 | 适合                                                   |
|--------------------------------------|--------------------------------------------------------|
| 推荐：`-e CHROMIUM_USER_FLAGS="..."` | 自己拼参数；Puppeteer 也吃得到                         |
| 自建 `Dockerfile.headless` 派生镜像  | 不想每次拼命令行；`docker run <自建镜像>` 就打一次冒烟 |
| 命令行直接传 `chromium --headless …` | 一次性排查，或脚本里参数各不相同                       |

三者的差别只在参数落在哪里：`CHROMIUM_USER_FLAGS` 由 Alpine 的 `/usr/lib/chromium/chromium-launcher.sh` 接在 `/etc/chromium/*.conf` 的系统默认值之后；自建 headless 镜像把一套默认值直接写进镜像的 `ENV`，并用 `tini` 当 PID 1；命令行参数优先级最高，适合临时覆盖。配方里的默认值是：

```text
--headless --no-sandbox --disable-dev-shm-usage --hide-scrollbars
--font-render-hinting=none --force-color-profile=srgb
--user-data-dir=/tmp/chromium-headless
```

```bash
# 推荐写法：参数走环境变量，命令本身只留任务相关参数
docker run --rm --init --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage \
      --hide-scrollbars --window-size=1440,900 \
      --font-render-hinting=none --force-color-profile=srgb" \
  -v "$PWD/out:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --virtual-time-budget=10000 --screenshot=/work/page.png https://example.com
```

参数本身有几条容易踩的事实：

- `--headless` 在 Chromium 132+ **就是新版无头**（`kDefaultHeadlessMode = kNewHeadlessMode`），本镜像里的 155 也一样；`--headless=new` 等价但多余，`--headless=old` 已失效——旧无头被拆成了独立的 `chrome-headless-shell`。
- 新版无头会自动注入 `--ozone-platform=headless`、`--use-angle=swiftshader`、`--no-first-run`，以及一个临时 `--user-data-dir`（你没显式指定时）。所以不要再手写这几个。
- `--no-sandbox` 只在 root 下必需（见下一节）。`--no-zygote` 只在配 `--no-sandbox` 时有意义，无头场景不需要；`--single-process` 是调试开关，新版无头下会随机崩。**这两个都不该出现在你的推荐参数里。**
- `--disable-gpu` 在新版无头下基本冗余：GPU 栈本来就是 SwiftShader / ANGLE 的软件路径，去掉它没有副作用。除非你要跑 WebGL / Canvas 且发现软件渲染不够，那时应该装 `chromium-swiftshader`（`--build-arg WITH_SWIFTSHADER=1`，约 5 MiB）并删掉 `--disable-gpu`。
- 自建的 headless 镜像内置了一套默认参数，但**默认镜像没有**。想关掉自建镜像的默认值：`docker run -e CHROMIUM_USER_FLAGS="" <自建镜像>`。

### `Running as root without --no-sandbox is not supported`

Chromium 的沙箱在 uid 0 下拒绝启动，并直接给出这句话。容器默认就是 root，所以这条报错在 root 下**必然出现**，不是镜像坏了：

```bash
docker run --rm --shm-size=1g docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --headless --no-sandbox --dump-dom about:blank
```

处置两条路，按你的场景选：

- 保持 root：带上 `--no-sandbox`（或换 `-headless` 变体，它已经内置）。这是单租户、只抓可信站点时最省事的组合。
- 要保留沙箱：镜像里预置了非 root 用户 `chrome`（UID/GID `10001`，家目录 `/home/chrome`），派生镜像里写一行 `USER chrome` 即可；`/work` 的属主也是 `chrome`，但 `-v $PWD:/work` 会覆盖属主，非 root 时可能写不进去。

`--no-sandbox` 始终是**使用方的运行时选择**，不在镜像里，理由见上一小节。

### `No usable sandbox!`

这条与上一条常被混为一谈，根因完全不同：报错出自 Chromium 启动时的 namespace 探测——容器或宿主不允许 unprivileged user namespace，SUID helper 也用不上，沙箱无法初始化。它与「是不是 root」无关，换成非 root 用户也可能照样出现。

```bash
# SUID helper 在不在、权限对不对（Alpine 的 chromium 包是 suid 的，正常应是 4755）
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest sh -c \
  'apk info -L chromium | grep chrome-sandbox | xargs ls -l'
# 宿主侧看 userns 是否被禁（字段是否存在取决于发行版）
sysctl kernel.unprivileged_userns_clone kernel.apparmor_restrict_unprivileged_userns 2>/dev/null
```

处置：

- 一次性验证：同样加 `--no-sandbox`，能立刻判断「是不是沙箱问题」——加了就正常，说明镜像本身没问题。
- 要真正保留沙箱：那是运行环境的事（宿主允许 unprivileged userns、或给容器 `--cap-add SYS_ADMIN`、或放宽 seccomp/AppArmor），不在本镜像能解决的范围内。
- 不要因为看到这条就以为「镜像坏了」：`chromium --version` 能输出、`--no-sandbox` 下渲染正常，就说明镜像完好。

沙箱取舍矩阵：

| 运行方式                                              | 需要的参数                                    | 沙箱   | 适用                 |
|-------------------------------------------------------|-----------------------------------------------|--------|----------------------|
| root（默认）                                          | `--no-sandbox`                                | 无     | 单租户、只抓可信站点 |
| 非 root + userns 可用                                 | 不用加                                        | 有     | 抓不可信页面         |
| 非 root + userns 被禁（Ubuntu 23.10+ 的 AppArmor 等） | 仍需 `--no-sandbox`，或 `--cap-add=SYS_ADMIN` | 视宿主 | —                    |

### `/dev/shm` 太小导致崩溃

Docker 默认给容器 `/dev/shm` 64MB，Chromium 用它做渲染进程的共享内存。页面元素多、分辨率高或并发截图时很快写满，表现为渲染进程崩溃、页面空白、退出码非 0，日志里常能看到 `shm` / `shared memory` 相关的字样。

```bash
# 1) 常规做法：放大 /dev/shm，同时让 Chromium 别把它当主战场
docker run --rm --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage" \
  -v "$PWD:/work" -w /work \
  docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --screenshot=/work/page.png https://example.com

# 2) 改不了 --shm-size 时（编排里没有对应字段、或你只有 docker run 的 tmpfs 权限）：显式挂一个更大的 tmpfs
docker run --rm --tmpfs /dev/shm:rw,size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox" \
  docker.cnb.cool/dtapp/alpine/chromium:latest chromium --dump-dom about:blank

# 3) 根文件系统只读时：/tmp 与 /dev/shm 都必须显式给可写落点
docker run --rm --read-only --shm-size=1g \
  --tmpfs /tmp:rw,size=1g --tmpfs /dev/shm:rw,size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage" \
  docker.cnb.cool/dtapp/alpine/chromium:latest chromium --dump-dom about:blank
```

几种手段的分工：

- `--shm-size=1g` 把 `/dev/shm` 放大，受宿主内存限制。
- `--disable-dev-shm-usage` 让 Chromium 改用 `/tmp` 而不是 `/dev/shm`，会占容器可写层——批量截图时注意容器磁盘占用。`/tmp` 是 1777，落盘没问题。
- `--tmpfs /dev/shm:rw,size=1g` 适合无法调 `--shm-size` 的环境，效果与调大 `/dev/shm` 等价，但不落在容器可写层。
- `--read-only` 时 `/tmp` 也变成只读，必须像上面第 3 条那样单独挂一个 tmpfs，否则 `--disable-dev-shm-usage` 反而会让它无处可写。

在没有权限调整 `/dev/shm` 的环境（部分托管 CI）里，`--disable-dev-shm-usage` 往往是唯一可用的手段；反过来，磁盘紧张但内存充裕时，优先调 `/dev/shm`。

### 并发实例互相踢：`SingletonLock`

root 运行、且 `$HOME` 属主也是 root 时，Alpine 的 `/usr/lib/chromium/chromium-launcher.sh` 会主动塞一个 `--user-data-dir=$HOME/.config/chromium`。同一台容器里起第二个浏览器实例就会撞上同一个 profile，报 `SingletonLock` / `profile appears to be in use`，表现为启动即失败或反复重启。

```bash
# 每个实例给独立目录，目录名带上你自己的任务标识
docker run --rm --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage --user-data-dir=/tmp/shot-1" \
  docker.cnb.cool/dtapp/alpine/chromium:latest chromium --dump-dom about:blank
```

`-headless` 变体把 `--user-data-dir` 固定在 `/tmp/chromium-headless`，单实例够用；同一容器里并发多个实例时要整套覆盖：`-e CHROMIUM_USER_FLAGS="..."` 是**替换**这个环境变量（不是追加），所以记得把 `--headless --no-sandbox --disable-dev-shm-usage` 一起写上，再把 `--user-data-dir` 指到各自的目录。

### 截图或 PDF 是空白

先分清「浏览器不可用」与「这个页面没渲染好」：`--dump-dom about:blank` 能正常输出，说明浏览器与依赖都在，问题在页面或参数。

三个常见原因：

| 原因                                      | 表现                             | 处置                                                |
|-------------------------------------------|----------------------------------|-----------------------------------------------------|
| 页面没加载完就截                          | 图片或文字只有一部分，或整页空白 | 加 `--virtual-time-budget=10000` 给等待上限         |
| 默认窗口太小（800x600），内容在可视区之外 | 只有页头，主体空白               | 加 `--window-size=1280,800`                         |
| 输出路径不可写                            | 退出码非 0，或文件根本不存在     | 挂载卷并用绝对路径，例如 `-v "$PWD:/work" -w /work` |

```bash
docker run --rm --shm-size=1g -v "$PWD:/work" -w /work \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage" \
  docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --window-size=1280,800 --virtual-time-budget=10000 \
  --screenshot=/work/page.png https://example.com
# 文件非空、退出码为 0 才算成功
ls -l page.png
```

截图成功但内容确实为空白，再怀疑页面本身：目标站点是否需要登录、是否依赖 `IntersectionObserver` 之类的滚动触发。这类等待策略命令行给不了，交给 puppeteer / playwright 控制。

### 中文显示成方块

主镜像渲染中文**必然是豆腐块**，不是「覆盖有限」：`font-freefont` 的 12 个 `.otf` 里，`cmap` 中的汉字 / 假名 / 谚文码位**全部为 0**（FreeSans 4622 个字形、FreeSerif 8087 个字形，其中 CJK 一个都没有），Chromium 自动带入的 `font-opensans` 同样不含 CJK。`font-freefont` 负责的是拉丁字母与符号，不是中文。

先确认容器里到底有没有中文字体：

```bash
# 默认镜像：输出为空
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest sh -c 'fc-list :lang=zh | head'
# 自建的 CJK 镜像：应当列出若干 Noto CJK 字族
docker run --rm my-chromium:cjk sh -c 'fc-list :lang=zh | head'
```

处置按场景选：

| 场景                    | 做法                                                                         | 体积代价               |
|-------------------------|------------------------------------------------------------------------------|------------------------|
| 需要中文截图 / 抓中文站 | 自建：`--build-arg WITH_CJK=1` 装 `font-noto-cjk`，简繁日韩全覆盖            | +88.8 MiB（installed） |
| 只要简体、想更省一点    | 派生镜像里装 `font-wqy-zenhei`（16.3 MiB，仅简体；本期未内置，属于下游自选） | 16.3 MiB               |
| 已有自己的一套字体      | 挂载字体目录后必须 `fc-cache -fv` 重建缓存                                   | 字体本身大小           |

```bash
# 自建带中文字形的镜像
docker build --build-arg WITH_CJK=1 -f .cnb/docker/Dockerfile.chromium -t my-chromium:cjk .

# 挂载自定义字体后重建缓存，否则 fontconfig 看不到新字族
docker run --rm -v "$PWD/fonts:/usr/share/fonts/custom:ro" \
  docker.cnb.cool/dtapp/alpine/chromium:latest sh -c \
  'fc-cache -fv && fc-list | grep -i custom | head'
```

- `font-noto`（9.0 MiB）**不含 CJK**，别拿它当中文方案；基础镜像里也没有它。
- `fontconfig` 包自带 `fc-list`、`fc-match`、`fc-cache`，用它们判断「字体在不在」比看截图快；构建期已经跑过 `fc-cache -f`。
- 需要给基础镜像加字体，就按「场景 + 体积代价」写进 PR（[CONTRIBUTING](../../CONTRIBUTING.md) 的硬性规则），不要往主镜像里随手塞。

### `chromium: not found`

`/usr/bin/chromium` 是本镜像里固定的二进制路径（它是包装脚本，转调 `/usr/lib/chromium/chromium`）。找不到通常只有三种原因：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest sh -c \
  'ls -l /usr/bin/chromium; chromium --version'
```

| 原因                                                | 判断                                                       |
|-----------------------------------------------------|------------------------------------------------------------|
| `FROM` 用的是纯 `alpine` 或别的基础镜像             | 检查派生镜像 `Dockerfile` 的 `FROM` 行                     |
| 派生镜像里删了包（`apk del chromium`、大范围 `rm`） | 检查派生镜像的清理步骤                                     |
| 拉到的不是本仓库产物（名字相似的另一镜像）          | 对照 commit 元数据里的 `chromium_image_digest` 确认 digest |

### 渲染 / 截图一直不返回

按「先证明浏览器可用，再证明网络可用，最后给上限」的顺序排：

```bash
# 1) 浏览器自身：不进网络，秒回说明渲染栈正常
docker run --rm --shm-size=1g \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage" \
  docker.cnb.cool/dtapp/alpine/chromium:latest chromium --dump-dom about:blank
# 2) 给等待上限，到点就出结果
docker run --rm --shm-size=1g -v "$PWD:/work" -w /work \
  -e CHROMIUM_USER_FLAGS="--headless --no-sandbox --disable-dev-shm-usage" \
  docker.cnb.cool/dtapp/alpine/chromium:latest \
  chromium --virtual-time-budget=10000 --screenshot=/work/page.png https://example.com
```

第 1 步就卡住，问题在容器（`/dev/shm`、sandbox 参数）；第 1 步正常、第 2 步卡住，问题在页面或网络：

- 页面有长轮询、websocket、永不结束的第三方脚本时，`load` 事件永远不会触发，必须给上限。
- 容器出不了网时，请求会挂到超时：先在容器内用继承自基座的 `curl -v` / `nc -zv` / `drill` 探活，再用宿主机侧命令复核目标可达与 DNS；真正的 `dig`（`bind-tools`）不在镜像里，见下一小节。
- HTTPS 页面报证书错误，先怀疑派生镜像裁掉了 `ca-certificates`。
- 顺带一提：如果你为了「减少进程」加过 `--single-process`，先删掉它再复测，它带来的随机崩溃很容易被误判成网络问题。

## 容器内：其它

### 镜像内路径与环境变量

排查前先对齐这几个固定值，省得在容器里翻目录：

| 项                                                         | 值                                                                                     |
|------------------------------------------------------------|----------------------------------------------------------------------------------------|
| 工作目录                                                   | `/work`（`WORKDIR`，属主 `chrome`；`-v $PWD:/work` 会覆盖属主，非 root 可能写不进去）  |
| 默认用户                                                   | root；镜像预置 `chrome`，UID/GID `10001`，家目录 `/home/chrome`，shell `/sbin/nologin` |
| 浏览器二进制                                               | `/usr/bin/chromium`（包装脚本，转调 `/usr/lib/chromium/chromium`）                     |
| `CHROME_BIN` / `CHROME_PATH` / `PUPPETEER_EXECUTABLE_PATH` | `/usr/bin/chromium`                                                                    |
| `PUPPETEER_SKIP_DOWNLOAD`                                  | `1`                                                                                    |
| `TZ` / `LANG` / `LC_ALL`                                   | `Asia/Shanghai` / `C.UTF-8` / `C.UTF-8`                                                |

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest sh -c \
  'env | grep -E "CHROME|PUPPETEER|^TZ=|^LANG=|^LC_"; id; pwd'
```

细节：

- `PUPPETEER_SKIP_DOWNLOAD=1` 是为了让派生镜像 `npm i puppeteer` 不再自带一份浏览器，直接用镜像里的 Chromium。确实需要官方 Chromium（例如要配套的 headless shell）时，在派生镜像里把它覆盖掉或删除。
- 默认 `USER` 仍是 root，这是既有取舍（root + `--no-sandbox` 是无头容器的常见组合）。要非 root：派生镜像写一行 `USER chrome`，并确认 `/work` 的写权限。
- 输出目录优先用 `/work`（构建期已 `chown chrome:chrome`），别写进容器可写层。

### 时区不对

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest sh -c 'date; cat /etc/timezone; ls -l /etc/localtime'
```

期望 `date` 显示 `CST`、`/etc/timezone` 为 `Asia/Shanghai`、`/etc/localtime` 指向 `/usr/share/zoneinfo/Asia/Shanghai`。派生镜像里常见三种破坏方式：删了 `tzdata`、覆盖了 `/etc/localtime`、在 `docker run` 时传了别的 `TZ`。基础镜像本身没问题的话，先查派生镜像的清理步骤。

### `curl` / `nc` / `drill` / `git` 找不到

先确认是不是用错了镜像：这几个工具由本仓库的 Alpine 基座提供，Chromium 镜像默认继承，正常情况下 `curl --version`、`nc -h`、`drill -v`、`git --version` 都能直接跑。报 `not found` 通常是 `FROM` 用了官方 `alpine` 或别的镜像，或者派生镜像裁掉了基座里的工具。

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest sh -c \
  'command -v curl nc drill git; curl --version | head -1'
```

仍然没有、或需要 `dig` / `nslookup`（`bind-tools` 没装），按需在派生镜像里补：

```dockerfile
# 该派生镜像确实需要在容器内排查时才加，并说明场景与体积代价
FROM docker.cnb.cool/dtapp/alpine/chromium:latest
RUN apk add --no-cache bind-tools
```

也可以直接在宿主机侧排查，把容器只当成执行渲染的地方。不要把额外的排障工具加进 Chromium 层——基座已经有一套，再叠加会让每个下游都背上重复的体积与攻击面（理由见 [安全基线](security-baseline.md)）。

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

当前可用的事件名是 `web_trigger_build_chromium` 与 `web_trigger_codewiki`。三处必须联动：workflow 里的触发键、`.cnb/web_trigger.yml` 的 `event`、`.cnb.yml` 的 `include` 列表。漏掉 `include` 时按钮存在但没人监听，表现为点下去没有任何构建记录。按钮的 `version` 输入项填的是 Alpine 版本，留空按 `latest` 处理。

## PR 门禁

### PR 被 SCA 拦住

`.cnb/workflows/sca.yml` 的 `pull_request.target` 给漏洞扫描与 License 扫描都设了 `failOnSeverity: high`，high 及以上即让流水线失败。这是唯一的硬门禁，先确认拦你的是哪一类：

```bash
# 本次改动是否碰了包的声明
git diff --stat -- .cnb/docker/Dockerfile.chromium
```

处置分三种：升级到已修复版本（换 Alpine 版本或换包）；确认是上游尚未修复的 CVE，那它不该在这个 PR 里解决，按 [安全基线](security-baseline.md) 的链条等上游；确认是误报后再动扫描配置。Chromium 依赖多，这类红灯里「上游未修的 Chromium / `nss` / `freetype` CVE」占比不低，不要为了过门禁注释掉 `failOnSeverity`——push 侧的全量报告会失去对照基线。

顺带说明：构建流水线只有手动与定时两个入口，PR 不会触发镜像构建，因此没有「PR 上跑一次 amd64 构建」的兜底；改完 Dockerfile 要么本地构建一次，要么手动触发流水线验证。

### AI 评审只评论不阻断

`fail_on_critical: false` 是刻意设置：评审输出建议，阻断权在 SCA。想让它更安静就调 `exclude_categories` 或 `min_severity`，不要靠忽略评论来「通过」检查。

## 相关文档

- [CI 流水线](ci-pipeline.md)
- [构建](build.md)
- [快速上手](getting-started.md)
- [构建元数据](metadata-and-badges.md)
- [维护手册](maintenance.md)
- [安全基线](security-baseline.md)
