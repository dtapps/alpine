# 安全基线

> 攻击面来自镜像里 Chromium 那一整套运行时依赖（显式 6 个包，加上由 `so:` 依赖自动带入的 9 个，闭包 184 个包），而不是本仓库的代码：这里把「镜像里进了什么」与「流水线扫了什么、失败了会不会拦住合并」逐项对上号，并说明 `.scanignore` 为什么只有两条排除。

## 前提

仓库里只有一份基础 `Dockerfile`（外加一个可选的 `-headless` 变体文件）和一串 CNB 流水线定义：没有应用代码、没有依赖清单、没有测试用例、没有自研二进制。安全基线因此只守两条边界。

| 边界       | 内容                                                                                                                      | 一旦放宽会怎样                             |
|------------|---------------------------------------------------------------------------------------------------------------------------|--------------------------------------------|
| 镜像内容面 | 进镜像的包全部来自上游 Alpine 源，安装动作只有一次 `apk add`（显式 6 个包，其余 9 个由 `chromium` 的 `so:` 依赖自动带入） | 供应链信任面扩大到「某个 URL 上的 tar 包」 |
| 扫描面     | 平台扫描能力覆盖整仓，`.scanignore` 只排除两张二进制图片                                                                  | 写死的凭证、越界的包不再被任何扫描发现     |

## 镜像内容面

| 面       | 现状                                                                                                                                                                                                                                                                                              | 理由                                                                                                                                           |
|----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------|
| 包来源   | 一次 `apk add` 显式装 6 个包：`chromium`、`ca-certificates`、`font-freefont`、`fontconfig`、`tzdata`、`tini`；`glib`、`pango`、`gdk-pixbuf`、`gtk+3.0`、`nss`、`freetype`、`harfbuzz`、`libstdc++`、`fontconfig` 这 9 个由 `chromium` 的 `so:` 依赖自动带入，不再单独声明；全部来自 Alpine 官方包 | 不存在把远程脚本管道喂给 shell 的装法，也不从 GitHub 取二进制                                                                                  |
| 运行用户 | 默认 root；镜像已预置 `chrome`（UID/GID 10001），但不切换 `USER`                                                                                                                                                                                                                                  | 这是无头 Chromium 的常见前提：容器内以 root 运行 Chromium 必须由使用方带 `--no-sandbox`。下游写一行 `USER chrome` 即可切换；生产请自行评估沙箱 |
| 排障工具 | 刻意不装 `curl`、`netcat-openbsd`、`bind-tools`                                                                                                                                                                                                                                                   | 镜像定位是「容器里能跑无头 Chromium」，不是「进容器就能探端口查 DNS」。要在容器内排障请基于本镜像派生，而不是要求这里加包                      |
| 体积     | 装包闭包实测（Alpine 3.24）：184 个包 / 761 MiB installed / 约 303 MiB 下载；镜像整体比纯 alpine 基础镜像大一个数量级                                                                                                                                                                             | `chromium` 是大型 C++ 程序，还要拉上 `gtk+3.0`、`pango`、`harfbuzz` 这套图形与文本栈，体积属于预期                                             |
| 制品签名 | 未签名                                                                                                                                                                                                                                                                                            | 制品库只负责存储与分发；强校验的替代手段是按 digest 固定拉取                                                                                   |
| 层扫描   | 未接入                                                                                                                                                                                                                                                                                            | 扫描覆盖的是 `Dockerfile` 里 `apk add` 的依赖声明，不是镜像层内的二进制                                                                        |
| 凭证     | 仓库内零凭证                                                                                                                                                                                                                                                                                      | 见下文「凭证只走 imports」                                                                                                                     |

容器内是 root、不装排障工具这两条是刻意选择而不是疏忽：`--no-sandbox`、`--disable-dev-shm-usage` 这类参数取决于使用方的运行环境（是否 root、`/dev/shm` 多大），写进基础镜像的 `ENTRYPOINT` 等于替下游决定启动方式，[CONTRIBUTING](../../CONTRIBUTING.md) 的硬性规则明确禁止。取舍的完整表述在 [SECURITY](../../SECURITY.md)。

## 受控例外：`-headless` 变体固化了启动参数

基础镜像仍然中性，但 `-headless` 变体（`.cnb/docker/Dockerfile.headless`，标签 `latest-headless` / `<version>-headless`）**确实**把一套默认参数写进了 `ENV CHROMIUM_USER_FLAGS`，其中包括 `--no-sandbox`，并带 `tini` 当 PID 1。这是**有意为之的变体**，不是对上述规则的绕过：

| 面       | 现状                                                      | 意味着什么                                                                        |
|----------|-----------------------------------------------------------|-----------------------------------------------------------------------------------|
| 沙箱     | 默认带 `--no-sandbox`（root 下不带它直接报错）            | 该变体默认无沙箱；只适合单租户、只抓可信站点的场景                                |
| 可撤销   | `docker run -e CHROMIUM_USER_FLAGS=""` 即清掉全部默认参数 | 需要沙箱时用基础镜像自己拼参数，或在变体上覆盖环境变量                            |
| 适用边界 | 面向「自用、不想每次都拼命令行」的场景                    | 派生镜像 / 生产用途必须自行评估沙箱需求，不要因为变体默认带 `--no-sandbox` 就沿用 |

参数本身没有新增供应链信任面（不下载、不执行外部脚本），但它改变了运行时的安全默认值，所以在这里单独列一条。基础镜像的取舍与完整参数说明见 [SECURITY](../../SECURITY.md) 与 [Dockerfile 解析](dockerfile.md)。

## 体积与依赖数量带来的攻击面

纯 alpine 镜像的攻击面是 `apk-tools` 加少量基础库；本镜像多出 Chromium 与它的一整套渲染依赖，多出来的部分集中在三处：

| 来源              | 表现                                                                                                                                               | 处置方式                                                                                                                                                                                                                                                     |
|-------------------|----------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 依赖数量          | 装包闭包实测 184 个包（显式 6 个 + 9 个由 `so:` 依赖带入 + 其余间接依赖），各有自己的 CVE 通告与修复节奏，SCA 报出的条目数量级上多于纯 alpine 镜像 | 每天 `01:30` 重建 `latest` 跟随上游；全量报告只作为基线，不为「让报告变绿」去排除路径                                                                                                                                                                        |
| Chromium 自身 CVE | 浏览器是高频披露的组件：渲染引擎、JS 引擎、网络栈都在其中                                                                                          | 本仓库不自行编译 Chromium，`chromium` 版本由所基于的 Alpine 版本仓库决定，因此**跟进节奏 = 上游 Alpine 仓库的节奏**；上游更新包后重建即带上，本仓库没有独立的修复动作。主版本漂移会被 `EXPECTED_CHROMIUM_MAJOR` 断言拦下（构建显式失败），不会被悄悄带进镜像 |
| 体积              | 闭包 761 MiB installed（3.24），层数不多但每层都大                                                                                                 | 体积本身不是漏洞，但层内二进制越多，未被当前扫描覆盖的 CVE 面就越大；见上文「镜像内容面」的「层扫描」一行                                                                                                                                                    |

对下游的含义：依赖 `latest` 的下游每天都在跟随 Chromium 补丁；钉在旧 digest 或旧版本标签上的下游不会自动获得任何 Chromium 修复。想要「既固定又跟进」的做法是定期重钉 digest，而不是长期不重建。

## 流水线扫描能力

| 能力                    | 触发事件                            | 关键配置                                                                 | 门禁                   |
|-------------------------|-------------------------------------|--------------------------------------------------------------------------|------------------------|
| 敏感信息扫描（secrets） | 平台内置，不由本仓库 workflow 定义  | `.cnb/security/code_scan_config.yml` 里 `ignoreFrom: .scanignore`        | 不在流水线内阻断       |
| 开源组件漏洞（SCA）     | `push` 全量 / `pull_request.target` | `scanMode: full` + `publish: true` / `failOnSeverity: high`              | push 出报告，PR 阻断   |
| License 扫描            | 同上                                | `scanMode: full` / `scanMode: diff` + `failOnSeverity: high`             | push 出报告，PR 阻断   |
| SBOM                    | 同上                                | `format: spdx` + `publish: true` / `scanMode: diff`                      | 不阻断                 |
| AI 代码评审             | `pull_request`                      | `model: deepseek-v4.1-flash`、`exclude_categories: style,nit`            | 不阻断                 |
| 扫描统计（sechook）     | `pull_request`                      | `max_display_authors: 5`、`sensitive_disabled: false`                    | 不阻断                 |
| 扫描配置自检            | `pull_request`                      | `args: [validate]`                                                       | 配置不合法即失败       |
| 镜像校验构建            | `pull_request`                      | `build-chromium.yml` 的 `validate-chromium`：`--load` 构建 amd64、不推送 | 三次冒烟任一失败即失败 |

门禁语义值得单独说清，因为它决定了「红灯要不要修」：

- push 侧的 `failOnSeverity` 在 `.cnb/workflows/sca.yml` 里是注释状态，只留 `publish: true`。全量扫描在 push 上的用途是留下报告基线：上游未修的 CVE 必然出现，若设门禁，每次 push 都会因为本仓库修不了的上游漏洞而变红，基线也就没人看了。注意 SCA 不挂在定时构建上，所以它是否门禁与 `latest` 是否继续跟随上游补丁无关。
- PR 侧的漏洞扫描与 License 扫描都写了 `failOnSeverity: high`，这是唯一的硬门禁：high 及以上必须在这一版里解决或证明是误报。
- AI 代码评审的 `fail_on_critical: false` 也是刻意设置：评审输出的是建议，阻断权留给 SCA。`exclude_categories: style,nit` 把风格与吹毛求疵类建议压掉，使评论集中在 security、bug、perf、maintainability。
- `cnb-sechook` 只汇总展示（统计各作者的问题分布），`code-security-config` 只校验扫描配置本身合法，两者都不看漏洞内容。
- `validate-chromium` 是另一类门禁，与漏洞无关：PR 里改了 Dockerfile 或装包参数时，用 `--load` 在 amd64 上构建一次、跑三次冒烟（`chromium --version`、`--dump-dom about:blank`、`date +%Z` 为 `CST`），不推送任何标签。它只证明「能构建、浏览器能起来」，把「改坏了要等次日定时任务才发现」提前到 PR 阶段。

SCA 扫描的对象是 `Dockerfile` 里 `apk add` 的依赖声明，所以这份报告天然把「Chromium 及其运行时依赖」当成本仓库的组件清单：显式 6 个包全部会进 SBOM，`chromium` 自己的 CVE 也在其中；由 `so:` 依赖带入的那些包同样在镜像里，但没有在 Dockerfile 里显式声明，报告的可读性比显式列出时差一些。

## `.scanignore` 的语义

`.scanignore` 是 gitignore 语义：文件里每一条都是「排除」，只有 `!` 前缀才是重新纳入。它被 `.cnb/security/code_scan_config.yml` 用 `ignoreFrom` 引用两次，对 secrets 与 SCA 都生效。

```yaml
secrets:
  scan:
    ignoreFrom: .scanignore

software-composition-analysis:
  scan:
    ignoreFrom: .scanignore
```

两类能力口径一致时集中写一份就够；只有某一类需要不同排除面时才改 `code_scan_config.yml`，让它指向另一个文件。当前 `.scanignore` 只有两条：`.cnb/bug.png` 与 `.cnb/hi.gif`，理由是二进制资源在 secrets 的高熵匹配里只会产生误报，SCA 也不解析图片。本仓库没有业务代码、没有依赖清单，因此也不需要为 `node_modules/`、`vendor/` 这类路径预先开口子。

原则是「排除面最小」：每多加一条，安全扫描面就少一块。所以规则按实际报出的路径补，绝不预先放宽——包括不提前写好 `node_modules/`、`vendor/`、`*.pem` 这类本仓库根本不存在的路径。

## 新增一条排除要写清什么

1. **为什么它是噪音**：二进制、生成物、压缩包，或者不参与解析的格式，写清依据而不是「感觉没用」。
2. **放弃了什么检测**：这条路径原本归哪类扫描、排除后会漏掉什么样的改动。若答不上来，说明它不该被排除。
3. **什么条件下能删掉**：例如 `.cnb/bug.png` 的注释里写了「若某次扫描并未对这两个文件报错，可以整段删除，让扫描面保持最大」。没有退出条件的排除会永久留在文件里。

当前刻意**不**排除的路径，以及原因：

| 路径                               | 留在扫描面内的理由                                                                                           |
|------------------------------------|--------------------------------------------------------------------------------------------------------------|
| `.cnb/docker/Dockerfile.chromium`  | SCA 的扫描对象：`apk add` 的包漏洞靠它发现，排除等于放弃 Chromium 检测                                       |
| `.cnb/docker/Dockerfile.headless`  | 只有 `ENV CHROMIUM_USER_FLAGS`、`ENTRYPOINT`、`CMD` 与标签，无凭证；保留才能发现「误把密钥写进 `ENV`」的改动 |
| `.cnb/scripts/build-chromium.sh`   | 只通过 `${CNB_TOKEN}` / `${CNB_TOKEN_USER_NAME}` 取值，无字面量凭证                                          |
| `.cnb/workflows/**`                | 只有 `${}` 引用，保留才能发现「误把密钥写进 `env`」的改动                                                    |
| `.cnb.yml`、`Makefile`、`.yamlfmt` | 配置与格式化规则，无凭证内容                                                                                 |

## 凭证只走 imports

构建流水线在 `imports` 里引入组织密钥仓库，脚本只读环境变量：

```yaml
imports:
  - https://cnb.cool/dtapp/envs/-/blob/main/docker.yml
  - .cnb/scripts/build-chromium.sh
```

```bash
# 仓库里只应出现变量引用，不应出现 token 字面量
grep -rn 'CNB_TOKEN' .cnb/
grep -rn 'CNB_TOKEN_USER_NAME' .cnb/
```

这也是为什么 `.scanignore` 不需要排除任何脚本：没有可排除的凭证，排除只会削弱「误写凭证」的检出能力。写死 token 会被敏感信息扫描拦下，但不能指望扫描兜底，硬性规则见 [CONTRIBUTING](../../CONTRIBUTING.md)。

## 依赖更新节奏

这个仓库的「依赖」分三层：`alpine:${ALPINE_VERSION}` 基础镜像、一次 `apk add` 显式装的 6 个包（含 `tzdata`）、以及由 `chromium` 的 `so:` 依赖自动带入的其余包（3.24 上整个闭包 184 个包 / 761 MiB installed）。三者都不锁具体包版本，补丁节奏等于上游 Alpine 的补丁节奏。

| 对象                                                                             | 版本由谁决定                                      | 补丁怎么进来                                                                                                              |
|----------------------------------------------------------------------------------|---------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|
| `alpine:${ALPINE_VERSION}`                                                       | `version` 入参，是 **Alpine 版本**；默认 `latest` | 定时构建或手动按钮，`FROM` 时取当时最新（构建固定带 `--pull`）                                                            |
| `chromium`                                                                       | 该 Alpine 分支仓库里的 chromium 包（3.24 = 155）  | **`CACHE_BUST` 每日击穿装包层缓存 + 定时任务**；换大版本只能换 Alpine 分支，主版本漂移会被 `EXPECTED_CHROMIUM_MAJOR` 拦下 |
| 其余显式包（`ca-certificates`、`font-freefont`、`fontconfig`、`tzdata`、`tini`） | 同上                                              | 同上                                                                                                                      |
| 由 `so:` 依赖带入的包（`glib`、`pango`、`nss`、`freetype` …）                    | 由 `chromium` 的依赖关系决定                      | 同上；它们随 `chromium` 一起升级，本仓库没有独立的升级动作                                                                |

`CACHE_BUST` 是装包层前面的一行 `echo`，CI 里取当天日期。没有它，跨轮次 registry 缓存命中后 `apk add` 根本不会重跑，上游补丁就永远进不了镜像——这比「每次重建都重新拉索引」更省，也更明确。

`version` 只影响 Alpine 版本，不能用来挑 Chromium 版本——这是与「浏览器发行版镜像」最容易混淆的一点。默认值必须钉分支还有一层原因：`chromium` 在 **community** 仓库，而 community 只维护到「下一个 stable 发布」，之后该分支的 chromium 就冻住了（3.20/3.21/3.22 分别停在 131/136/142，3.20 已 EOL）；长期停在老分支等于把浏览器 CVE 锁死。

主版本漂移有专门的拦网：`EXPECTED_CHROMIUM_MAJOR`（默认 `155`）在构建期断言 `chromium --version` 的主版本，不符时构建**显式失败**并打印实际版本。定时任务某天变红通常就是上游换主版本了，处置方式是确认渲染冒烟通过后更新默认值，或传 `--build-arg EXPECTED_CHROMIUM_MAJOR=any` 跳过。

| 标签        | 更新方式                                  | 补丁进入镜像的时间 |
|-------------|-------------------------------------------|--------------------|
| `latest`    | 每天 `01:30`（Asia/Shanghai）定时构建一次 | 上游发版后最迟次日 |
| `<version>` | 不自动跟随，需手动点按钮并填 `version`    | 由人决定           |

推荐的处理链条「上游已修则重建」：

```text
SCA 报告出现 high / critical
  → 确认是哪个包（chromium / nss / freetype / tzdata …）
  → 查上游 Alpine 是否已发布该包的修复版本
      ├─ 已修复 → 重建：latest 等次日 00:05 自动跟随，或立即手动触发
      │            版本标签（如 3.24.3）必须手动填 version 才会带上修复
      └─ 未修复 → 无可执行动作，等上游；不要用 .scanignore 或注释 failOnSeverity
                  让报告消失，否则「上游已修」的时点就无人发现
```

若命中的是 `chromium` 自身的 CVE，判断依据同样在上游 Alpine 的包版本，而不是 Chromium 项目的发布时间表：上游把带修复的包推进仓库后，下一次重建才会进入镜像。

历史镜像不做回溯修复，按 digest 固定的旧产物不会带上任何后续补丁。整体取舍见 [维护手册](maintenance.md) 与 [SECURITY](../../SECURITY.md)。

## 报告问题

先分清是「本仓库的配置/流水线问题」「上游 Alpine 包漏洞」还是「敏感问题」，三类的渠道不同，敏感问题不要开公开 issue。分类表与报告要素在 [SECURITY](../../SECURITY.md)；提交前请先看 [CONTRIBUTING](../../CONTRIBUTING.md) 的流程约定。

报告 Chromium 渲染相关问题时，请说明是否带 `--no-sandbox`、`/dev/shm` 大小与完整的启动参数，否则很难区分「镜像缺依赖」与「运行参数不对」，排查路径见 [排错手册](troubleshooting.md)。

## 相关文档

- [SECURITY](../../SECURITY.md)
- [CI 流水线](ci-pipeline.md)
- [维护手册](maintenance.md)
- [排错手册](troubleshooting.md)
- [架构](architecture.md)
