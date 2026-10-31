# APK 源与网络策略

> 换掉 `dl-cdn.alpinelinux.org` 是为了让构建在国内不卡在第一步：只留「国内镜像站 + 官方兜底」两组共四行，索引与包的签名仍由 Alpine 官方公钥校验。

## 为什么换源

- 官方源 `dl-cdn.alpinelinux.org` 在国内解析与下载都不稳定。`apk add` 卡在这里，表现为流水线超时，失败点却不在代码上，排查成本高。本镜像要装的又是 Chromium 这种大包，源慢的代价比装几个小工具明显得多。
- 换源只改 `/etc/apk/repositories` 这一个文本文件，不改变包的来源身份：包仍由 Alpine 官方构建并签名，镜像站只承担分发。
- 收益是构建速度与稳定性，代价是信任面变大——这件事在 [SECURITY](../../SECURITY.md) 里被列为已知取舍，最后一节展开。

## 为什么只留两组源

早期版本写的是五个镜像站（cernet、腾讯云、阿里云、火山、官方）乘 `main`/`community` 共十行；仓库已收敛成两组四行：`mirrors.cernet.edu.cn` 加官方 `dl-cdn.alpinelinux.org` 兜底。

- **多站混用会撞依赖版本。** 各镜像站的同步进度并不一致，十行仓库最终会被 apk 合并成一张包视图，同一个包在不同站是不同快照时，apk 取版本更高的那一份。一次 `apk add` 里如果 `chromium` 来自 A 站的 `community`、某个 `so:` 依赖来自 B 站的 `main`，就可能拿到彼此不匹配的组合，表现为依赖求解失败或 `so:` 解析不到——而这种失败只在某个站刚同步完、另一个站还没同步的窗口期出现，最难复现。
- **十行就是十份索引请求。** `main` 与 `community` 各算一个独立仓库，每个仓库都要拉一份 `APKINDEX`。行数减半，构建起步阶段的请求数、重试等待与 `WARNING` 噪声一起减半，而可用性并没有变差：真正兜底的是官方源，多出来的中间站只在「cernet 与官方同时不可达」时才有意义，那种情况本身极罕见。
- 顺序的两层含义仍然成立：先被尝试的源决定速度，版本相同时先列出的源决定取哪一份。调整顺序属于对外行为变更，[CONTRIBUTING](../../CONTRIBUTING.md) 要求说明理由。

## ALPINE_VER 怎么推导

```dockerfile
RUN ALPINE_VER=$(cut -d. -f1,2 /etc/alpine-release) \
    && printf '%s\n' \
        "https://mirrors.cernet.edu.cn/alpine/v${ALPINE_VER}/main" \
        "https://mirrors.cernet.edu.cn/alpine/v${ALPINE_VER}/community" \
        "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main" \
        "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" \
        >/etc/apk/repositories
```

- `/etc/alpine-release` 的内容形如 `3.24.3`（major.minor.patch），而 APK 仓库路径只到 `major.minor`，即 `v3.24`，所以取前两段再拼 `v`。
- 在容器内读文件推导，而不是从 `ARG ALPINE_VERSION` 截取：那个 ARG 默认是 `latest`、也可接受具体版本号（见[CI 流水线](ci-pipeline.md)的入参校验），而 `latest` 拼不出一条有效的仓库 URL。
- 在容器内读还能自动对齐：哪天把默认值改成 `3.25.x`，仓库路径自动变成 `v3.25`，这段一行都不用改。
- 前提是 `FROM` 用的是真实存在的标签；`version` 传了不存在的版本会先在 `FROM` 阶段失败，不会走到这里。

顺带说明一个常被搞混的点：这里的版本号是 **Alpine 版本**，Chromium 的版本由该 Alpine 版本的软件包仓库决定，不受 `version` 入参控制。而且 `chromium` 在 **community** 仓库，Alpine 的 community 只维护到「下一个 stable 发布」，所以每个分支的 Chromium 会冻住——3.24 当前是 `155.0.8059.84-r0`（仓库里的包版本，带 apk 的 `-rN` 修订），老分支停在更早的主版本。

## 两组源的顺序

| 顺序 | 源     | URL 前缀                         | 角色                       |
|------|--------|----------------------------------|----------------------------|
| 1    | cernet | `https://mirrors.cernet.edu.cn`  | 教育网与公网都快，日常走它 |
| 2    | 官方   | `https://dl-cdn.alpinelinux.org` | 原始出处，兜底             |

每组源写两行（`.../alpine/v${ALPINE_VER}/main` 与 `.../alpine/v${ALPINE_VER}/community`），共四行写入 `/etc/apk/repositories`。`main` 与 `community` 都要留：`apk add` 只认包名、不指定仓库，少写哪个仓库就少一份索引，缺包时表现为「包不存在」而不是「源有问题」。

容器里看实际生成的内容：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest cat /etc/apk/repositories
```

实际就是四行（以 `3.24` 为例）：

```text
https://mirrors.cernet.edu.cn/alpine/v3.24/main
https://mirrors.cernet.edu.cn/alpine/v3.24/community
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
```

## 不需要单独的 apk update 层

早期版本的 Dockerfile 在换源同一个 `RUN` 末尾还有一条 `apk update --no-cache`，理由是「换完源立刻验证可达」。现在删掉了，因为 `apk add` 自带索引拉取：

- `apk add --no-cache` 会为每个仓库拉一份 `APKINDEX`，源不可达在装包层立刻暴露，日志里既有 `WARNING` 也有缺包名。专门跑一次 `apk update` 不改变装包层的任何行为。
- `--no-cache` 让索引用完即弃、不落盘，所以那条 `apk update` 在镜像里什么也没留下，紧接着的 `apk add` 还要再拉一遍。它唯一产物是一行日志，代价是每次构建多下一份全量索引、多等一轮网络请求。
- 结论：源可达性由装包层顺带验证，不必为它单独埋一条命令。判断方式见下文「验证某个源现在可用」。

## apk 的仓库尝试语义

- apk 没有优先级字段，`/etc/apk/repositories` 的**行序就是回退序**；每一行是一个独立仓库，`main` 与 `community` 各算一份索引。
- 每次 `apk add`（以及任何需要索引的子命令），apk 为每个仓库取一份 `APKINDEX`，把多份索引合并成一张包视图。
- 单个源不可达只会打印 `WARNING` 并继续，用其余源照常解析；只有当所有源都取不到索引，或者所有源都没有目标包时，命令才失败。
- 同一个包在多个源里都有、版本相同时，先列出的源胜出；版本不同时取版本更高的那一份。所以「换源」不会让包悄悄降级。也正是这条规则，让「多站混用」在同步窗口期变得危险，见上文。
- 因此实际生效的是「可用源的并集」，而不是「第一个源的镜像」：cernet 挂了，构建仍能用官方源走完，只是多了几行 `WARNING` 和等待超时的几秒。

## 验证某个源现在可用

索引 URL 形如 `https://<mirror>/alpine/v3.24/main/<arch>/APKINDEX.tar.gz`，`<arch>` 是 `x86_64` 或 `aarch64`。先用镜像里的实际版本号替换示例里的 `3.24`：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest cat /etc/alpine-release
```

下面的循环用 `curl`，所以它在**宿主机**上跑，不在容器里跑——本镜像刻意不装 `curl`（只提供浏览器与依赖，见 [Dockerfile 解析](dockerfile.md)）：

```bash
VER=3.24
for host in mirrors.cernet.edu.cn dl-cdn.alpinelinux.org; do
  printf '%-28s ' "$host"
  curl -sSI -o /dev/null -w '%{http_code} %{time_total}s\n' \
    "https://${host}/alpine/v${VER}/main/x86_64/APKINDEX.tar.gz"
done
```

`200` 表示索引可取，耗时那一列可以直接看出两条线路快慢；`403` / `404` 多为路径或版本号写错；连不上或超时则是网络问题。

容器内的验证走的是镜像里的源配置，比在宿主机上测更贴近真实构建。镜像里没有 `curl`，但有 `apk`，所以用「只解析、不安装」跑一遍装包：

```bash
docker run --rm docker.cnb.cool/dtapp/alpine/chromium:latest \
  sh -c 'apk add --no-cache --simulate tini'
```

`--simulate` 让它只打印将要装的包、不真正写入，但索引请求照发：输出里出现 `WARNING` 的那几行就是当前不可达的源；想让结果更直白，去掉 `--simulate` 真的装一次 `tini`（23 KiB）也行。这也是「源验证不必单开一层」的直接依据——它和构建时的装包路径完全一样。

## 源挂掉时怎么改

1. 先用上一节宿主机侧的 `curl` 循环区分「某个源挂了」和「整条网络不通」。
2. 只动 `.cnb/docker/Dockerfile.chromium` STEP 1 里对应的两行（同一源的 `main` 与 `community`）：调顺序就是把两行整段搬位置，弃用就是整段删掉两行。两个仓库是成对的，别只删 `community` 留下一半。
3. 整段是 `printf '%s\n' 若干URL >/etc/apk/repositories`：URL 只是 `printf` 的参数，末尾只有一个重定向。别把 `>` / `>>` 混进参数列表——shell 先做重定向再跑 `printf`，结果是文件被截断或只有最后一个重定向生效，最终只剩一个源，而且构建不报错。
4. 本地验证：`docker build -f .cnb/docker/Dockerfile.chromium -t alpine-chromium:local .`，再按上一节跑一次 `apk add --no-cache --simulate tini`，确认没有新的 `WARNING`。
5. 跑 `make format-docker` 让 `dockerfmt` 统一格式，提交时在 PR 里写明「哪个源、什么症状、什么时候观测到」。
6. 不要因为 cernet 出问题就顺手删掉官方源：删掉等于把「镜像站故障」直接变成构建彻底失败。

## 供应链信任面

- 信任面 = 上游 Alpine + 这一个国内分发站，已在 [SECURITY](../../SECURITY.md) 的「已知取舍」里写明。
- 镜像站能做的：返回索引与包、拒绝服务、返回旧快照（构建拿到的是过期版本的包）。
- 镜像站无法悄悄塞进一个恶意包：apk 用 `/etc/apk/keys/` 里的 Alpine 官方公钥校验仓库索引与每个 `.apk` 包的签名，签名不符直接拒绝安装。
- 因此换源主要影响**可用性**与**时效性**，不影响包内容的真实性；剩下的风险是构建指纹（源站能看到你请求了哪些包与版本）和「被喂旧索引导致镜像停留在旧包上」。
- 后一条正是每天 `01:30`（Asia/Shanghai）重建 `latest` 的意义之一：固定节奏重跑，旧索引最多影响一天，详见[维护手册](maintenance.md)。注意定时任务只产出 `latest` 系列标签，版本标签只能手动触发，所以 `3.24` 这类标签不会自动跟上游补丁。
- 补丁要真进镜像，还得靠 `CACHE_BUST` 每天击穿装包层缓存——只换源、只重跑定时任务，装包层仍可能一直命中缓存，机制见[CI 流水线](ci-pipeline.md)的「构建参数与缓存击穿」。
- 不要在源 URL 里放任何凭证：本仓库只引用公开镜像站，不存在私有源与鉴权参数。

## 为什么保留官方源兜底

- 国内镜像站是镜像，同步有延迟，`community` 里的小众包偶尔会缺；官方源是包的原始出处，缺包概率最低。
- 放在最后不影响速度：只有前面连不上，或前面没有目标包时才会走到它，正常构建几乎碰不到。
- 成本只有两行文本和一次尝试；收益是「镜像站故障」时构建仍能完成。
- 它同时是判断基准：cernet 行为异常时，把官方源临时挪到第一位，就能确认是镜像站的问题还是包本身的问题。

## 相关文档

- [文档索引](README.md)
- [Dockerfile 解析](dockerfile.md)
- [CI 流水线](ci-pipeline.md)
- [安全基线](security-baseline.md)
- [排错手册](troubleshooting.md)
