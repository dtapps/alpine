# 安全基线

> 攻击面来自上游 Alpine 而不是本仓库的代码：这里把「镜像里进了什么」与「流水线扫了什么、失败了会不会拦住合并」逐项对上号，并说明 `.scanignore` 为什么只有两条排除。

## 前提

仓库里只有一份 `Dockerfile` 和一串 CNB 流水线定义：没有应用代码、没有依赖清单、没有测试用例、没有自研二进制。安全基线因此只守两条边界。

| 边界       | 内容                                                         | 一旦放宽会怎样                             |
|------------|--------------------------------------------------------------|--------------------------------------------|
| 镜像内容面 | 进镜像的包全部来自上游 Alpine 官方源，安装动作只有 `apk add` | 供应链信任面扩大到「某个 URL 上的 tar 包」 |
| 扫描面     | 平台扫描能力覆盖整仓，`.scanignore` 只排除两张二进制图片     | 写死的凭证、越界的包不再被任何扫描发现     |

## 镜像内容面

| 面       | 现状                                                                                               | 理由                                                          |
|----------|----------------------------------------------------------------------------------------------------|---------------------------------------------------------------|
| 包来源   | `ca-certificates`、`curl`、`netcat-openbsd`、`bind-tools`、`tzdata`，全部由 `apk` 从 Alpine 源安装 | 不存在把远程脚本管道喂给 shell 的装法，也不从 GitHub 取二进制 |
| 运行用户 | root                                                                                               | 定位是基础调试镜像；生产请在派生镜像里自行加 `USER`           |
| 网络能力 | 预装 `netcat-openbsd`（`nc`）与 `bind-tools`（`nslookup`、`dig`）                                  | 排障要在容器内直接探端口、查 DNS；不需要就基于本镜像裁剪      |
| 制品签名 | 未签名                                                                                             | 制品库只负责存储与分发；强校验的替代手段是按 digest 固定拉取  |
| 层扫描   | 未接入                                                                                             | 扫描覆盖的是 `Dockerfile` 的依赖声明，不是镜像层内的二进制    |
| 凭证     | 仓库内零凭证                                                                                       | 见下文「凭证只走 imports」                                    |

容器内是 root、预装网络工具这两条是刻意选择而不是疏忽：这个镜像的用途是「拉下来就能进容器排障」，把 `nc`、`dig` 砍掉或加 `USER` 会让每个下游项目重复做一遍裁剪。取舍的完整表述在 [SECURITY](../SECURITY.md)。

## 流水线扫描能力

| 能力                    | 触发事件                            | 关键配置                                                          | 门禁                 |
|-------------------------|-------------------------------------|-------------------------------------------------------------------|----------------------|
| 敏感信息扫描（secrets） | 平台内置，不由本仓库 workflow 定义  | `.cnb/security/code_scan_config.yml` 里 `ignoreFrom: .scanignore` | 不在流水线内阻断     |
| 开源组件漏洞（SCA）     | `push` 全量 / `pull_request.target` | `scanMode: full` + `publish: true` / `failOnSeverity: high`       | push 出报告，PR 阻断 |
| License 扫描            | 同上                                | `scanMode: full` / `scanMode: diff` + `failOnSeverity: high`      | push 出报告，PR 阻断 |
| SBOM                    | 同上                                | `format: spdx` + `publish: true` / `scanMode: diff`               | 不阻断               |
| AI 代码评审             | `pull_request`                      | `model: deepseek-v4.1-flash`、`exclude_categories: style,nit`     | 不阻断               |
| 扫描统计（sechook）     | `pull_request`                      | `max_display_authors: 5`、`sensitive_disabled: false`             | 不阻断               |
| 扫描配置自检            | `pull_request`                      | `args: [validate]`                                                | 配置不合法即失败     |

门禁语义值得单独说清，因为它决定了「红灯要不要修」：

- push 侧的 `failOnSeverity` 在 `.cnb/workflows/sca.yml` 里是注释状态，只留 `publish: true`。全量扫描在 push 上的用途是留下报告基线：上游未修的 CVE 必然出现，若设门禁，每天 `00:05` 的定时构建会因为本仓库修不了的上游漏洞而停摆，镜像反而停止跟随补丁。
- PR 侧的漏洞扫描与 License 扫描都写了 `failOnSeverity: high`，这是唯一的硬门禁：high 及以上必须在这一版里解决或证明是误报。
- AI 代码评审的 `fail_on_critical: false` 也是刻意设置：评审输出的是建议，阻断权留给 SCA。`exclude_categories: style,nit` 把风格与吹毛求疵类建议压掉，使评论集中在 security、bug、perf、maintainability。
- `cnb-sechook` 只汇总展示（统计各作者的问题分布），`code-security-config` 只校验扫描配置本身合法，两者都不看漏洞内容。

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

两类能力口径一致时集中写一份就够；只有某一类需要不同排除面时才改 `code_scan_config.yml`，让它指向另一个文件。当前 `.scanignore` 只有两条：`.cnb/bug.png` 与 `.cnb/hi.gif`，理由是二进制资源在 secrets 的高熵匹配里只会产生误报，SCA 也不解析图片。

原则是「排除面最小」：每多加一条，安全扫描面就少一块。所以规则按实际报出的路径补，绝不预先放宽——包括不提前写好 `node_modules/`、`vendor/`、`*.pem` 这类本仓库根本不存在的路径。

## 新增一条排除要写清什么

1. **为什么它是噪音**：二进制、生成物、压缩包，或者不参与解析的格式，写清依据而不是「感觉没用」。
2. **放弃了什么检测**：这条路径原本归哪类扫描、排除后会漏掉什么样的改动。若答不上来，说明它不该被排除。
3. **什么条件下能删掉**：例如 `.cnb/bug.png` 的注释里写了「若某次扫描并未对这两个文件报错，可以整段删除，让扫描面保持最大」。没有退出条件的排除会永久留在文件里。

当前刻意**不**排除的路径，以及原因：

| 路径                               | 留在扫描面内的理由                                                  |
|------------------------------------|---------------------------------------------------------------------|
| `.cnb/docker/Dockerfile`           | SCA 的扫描对象：`apk add` 的包漏洞靠它发现，排除等于放弃检测        |
| `.cnb/scripts/build-image.sh`      | 只通过 `${CNB_TOKEN}` / `${CNB_TOKEN_USER_NAME}` 取值，无字面量凭证 |
| `.cnb/workflows/**`                | 只有 `${}` 引用，保留才能发现「误把密钥写进 `env`」的改动           |
| `.cnb.yml`、`Makefile`、`.yamlfmt` | 配置与格式化规则，无凭证内容                                        |

## 凭证只走 imports

构建流水线在 `imports` 里引入组织密钥仓库，脚本只读环境变量：

```yaml
imports:
  - https://cnb.cool/dtapp/envs/-/blob/main/docker.yml
  - .cnb/scripts/build-image.sh
```

```bash
# 仓库里只应出现变量引用，不应出现 token 字面量
grep -rn 'CNB_TOKEN' .cnb/
grep -rn 'CNB_TOKEN_USER_NAME' .cnb/
```

这也是为什么 `.scanignore` 不需要排除任何脚本：没有可排除的凭证，排除只会削弱「误写凭证」的检出能力。写死 token 会被敏感信息扫描拦下，但不能指望扫描兜底，硬性规则见 [CONTRIBUTING](../CONTRIBUTING.md)。

## 依赖更新节奏

这个仓库的「依赖」就是 `Dockerfile` 里 `apk add` 的五个包加上 `alpine:${ALPINE_VERSION}` 基础镜像本身，因此补丁节奏等于上游 Alpine 的补丁节奏。

| 标签        | 更新方式                                  | 补丁进入镜像的时间 |
|-------------|-------------------------------------------|--------------------|
| `latest`    | 每天 `00:05`（Asia/Shanghai）定时构建一次 | 上游发版后最迟次日 |
| `<version>` | 不自动跟随，需手动点按钮并填 `version`    | 由人决定           |

推荐的处理链条「上游已修则重建」：

```text
SCA 报告出现 high / critical
  → 确认是哪个包（curl / openssl / tzdata …）
  → 查上游 Alpine 是否已发布该包的修复版本
      ├─ 已修复 → 重建：latest 等次日 00:05 自动跟随，或立即手动触发
      │            版本标签（如 3.20）必须手动填 version 才会带上修复
      └─ 未修复 → 无可执行动作，等上游；不要用 .scanignore 或注释 failOnSeverity
                  让报告消失，否则「上游已修」的时点就无人发现
```

历史镜像不做回溯修复，按 digest 固定的旧产物不会带上任何后续补丁。整体取舍见 [维护手册](maintenance.md) 与 [SECURITY](../SECURITY.md)。

## 报告问题

先分清是「本仓库的配置/流水线问题」「上游 Alpine 包漏洞」还是「敏感问题」，三类的渠道不同，敏感问题不要开公开 issue。分类表与报告要素在 [SECURITY](../SECURITY.md)；提交前请先看 [CONTRIBUTING](../CONTRIBUTING.md) 的流程约定。

## 相关文档

- [SECURITY](../SECURITY.md)
- [CI 流水线](ci-pipeline.md)
- [维护手册](maintenance.md)
- [架构](architecture.md)
