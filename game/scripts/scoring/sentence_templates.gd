class_name SentenceTemplates
extends RefCounted

## 五维诊断语句模板表（评分侧独立资产）。
##
## 依据：docs/10-契约/mini-codex.md §4.1（给诊断语句不给分数、不评聪明、句子要能告诉
## 学员"下一步改哪里"）、docs/10-契约/交互方案.md §七（评分要用另一个 codex 实例——
## 至少另一次调用 + 另一套提示词）。
##
## 「另一实例」口径：这套模板只被评分代码（five_dim_scorer / scorer_service /
## llm_bridge）引用，与被评任务的执行代码（levels/、core/、compiler/）零共享；
## demo 阶段它就是"另一个评分实例"的提示词表，将来接真 LLM 时同一张表拼进
## sidecar 的 system prompt（调用形状见 llm_bridge.gd 注释）。
##
## 规则：全部中文；只给句子不给分数；每句带「下一步改哪里」的指引；
## 占位符用 {key}，由 five_dim_scorer 用 String.format 填，数字一律从步记录实算。

# ---- 中性句（拿不出证据的维度不编话） ----
const NEUTRAL := "这一版看不出{dim}上的问题；{hint}"
const HINT_CORRECTNESS := "保持每一步都进步记录，判定和复盘才有据可查"
const HINT_STRUCTURE := "保持一阶段一件事，装置上每段的落点才看得清"
const HINT_EFFICIENCY := "维持这个动作规模，改参重跑的成本就低"
const HINT_ROBUSTNESS := "想更稳，可以故意喂一个坏输入，看它会不会被校验拦下"
const HINT_READABILITY := "回看时先读每步的 caption 就能复盘，保持这个习惯"

# ---- 正确性（目标达成没有） ----
const COR_EMPTY := "这份记录一步都没有，没法对照目标；先跑一遍再交评分"
const COR_MISSING_PHASE := "任务没有跑完：缺少「{phase}」阶段的步骤（第 {last} 步后没有下文）；下一步把「{phase}」这一段补上，再交评分"
const COR_FORBIDDEN := "第 {at} 步用了本关不该用的 {tool}；先把它撤下来，换成过关检查要求的动作再跑一遍"
const COR_MISSING_PATTERN := "目标动作没做完：没看到{desc}（第 {last} 步后没有下文）；下一步对照过关检查把这步补上"
const COR_RUNS_SHORT := "目标要求跑 {want} 遍（含改参后重跑），这份记录只跑了 {got} 遍；改一个参数再跑一遍，看看两版差在哪"
const COR_DONE := "任务跑完了：{summary}——从第 {first} 步推进到第 {key} 步，全程都在步记录里；想再练一版，可以改一个参数重跑对比差异"

# ---- 结构（流程拆得清不清） ----
const STR_MISSING_ASSETS := "装置还缺组件：{assets} 没有装上（安装段在第 {ref} 步附近）；下一步先把缺的组件放进工位再跑"
const STR_ORDER := "阶段顺序反了：「{late}」跑在了「{early}」前面（第 {a} 步在第 {b} 步之前）；按 看→装→跑→评 的顺序重排一遍再跑"
const STR_STACKED := "第 {a}–{b} 步在重复堆叠同一个动作（{n} 次），合并成一次、或拆成 读→做→写 三段会更清楚"
const STR_CROWDED := "你把所有活都放在「{phase}」一个阶段里，拆成 读→做→写 分段推进，回看时每段的落点才看得清（从第 {a} 步开始的那一串）"

# ---- 效率（步数与改动次数，ops 取自步记录） ----
const EFF_OVER_REPEAT := "用了 {total} ops，基线 {baseline}——多出来的主要在重复读同一处（{refs}）；下一步先把这些重复读取合并掉，再跑一遍对比 ops"
const EFF_OVER_TOP := "用了 {total} ops，基线 {baseline}——大头集中在{refs}这几步；下一步看看这几步的动作能不能省下一半"
const EFF_OK := "本次 {total} ops，不高于基线 {baseline}（最大一步在第 {top} 步）；这个动作规模可以接受，改参重跑也便宜"
const EFF_NO_BASELINE := "本次共 {total} ops（最大一步在第 {top} 步）；这关还没定 ops 基线，先记下这个数，多跑两遍就有对照了"

# ---- 鲁棒性（边界情况处理没有） ----
const ROB_FAIL_OPEN := "坏输入直接进了执行，第 {fail} 步崩了（{code}），之后没有重试；先过校验门再执行就不会——下一步在执行之前加一道校验"
const ROB_FAIL_CLOSED := "第 {fail} 步崩了（{code}），第 {retry} 步重试接上、闭环成立；把校验提到执行之前，这次重试的 ops 就能省下来"
const ROB_NO_VALIDATION := "没看到校验步：这一版任何输入都直接进执行（第 {exec} 步），坏输入来了会原样崩；下一步在执行之前加一次校验"

# ---- 可读性（别人看得懂吗） ----
const REA_NO_TASK := "没看到写下来的任务描述（第 {ref} 步装上任务牌后一直没写字）；把要做的事写具体，下一个接手的人才不用猜"
const REA_MISSING_KW := "任务描述里没说{kw}，下一个接手的人要猜；在第 {ref} 步的任务文本里补上这一句再跑一遍"
const REA_CAPTIONS := "有 {n} 步没有说明文字（{refs}），回看 run 记录时看不出当时在做什么；给每一步补一句 caption"
const REA_OK := "任务描述写得具体（「{text}」），绝大多数步骤都带说明文字（覆盖率 ≥80%），回看 run 记录能复盘；保持这个习惯，接手的人不用猜"
