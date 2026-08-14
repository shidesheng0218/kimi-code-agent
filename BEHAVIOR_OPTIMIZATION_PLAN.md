# Kimi Agent 行为模式优化方案

## 问题现状

### 当前表现
- ❌ 用户问"大连天气如何"，回答"我没有实时天气数据源"
- ❌ 不主动尝试使用工具（WebSearch）
- ❌ 过早放弃，不展示尝试过程
- ❌ 行为模式保守，不像 Claude Code

### Claude Code 的表现
- ✅ 立即尝试使用工具
- ✅ 显示"Searching for..."过程
- ✅ 失败后才说明原因
- ✅ 主动、积极的执行风格

## 核心问题分析

### 1. Kimi SDK 的限制
```typescript
interface SessionOptions {
    workDir: string;
    model?: string;
    externalTools?: ExternalTool[];
    // ❌ 没有 systemPrompt 参数
}
```

**结论：** 无法通过 SDK API 直接注入 system prompt

### 2. 可能的注入点

| 方法 | 位置 | 可行性 | 影响范围 |
|------|------|--------|----------|
| SDK systemPrompt | API 参数 | ❌ 不支持 | - |
| 项目配置文件 | `.kimi/` | ✅ 可行 | 单个项目 |
| 全局配置 | 用户目录 | ✅ 可行 | 所有项目 |
| 工具定义 | ExternalTool.description | ✅ 可行 | 工具层面 |
| 启动参数 | Swift 层 | ⚠️ 复杂 | 全局 |

## 优化方案

### 方案 A：项目级配置文件（推荐）⭐

**原理：** 创建 `.kimi/agent.md` 配置文件，Kimi SDK 会自动加载

**优点：**
- ✅ 简单直接
- ✅ 项目级别，不影响其他项目
- ✅ 用户可以自定义
- ✅ 符合 Kimi SDK 设计

**实现步骤：**

1. **创建配置文件模板**
```bash
.kimi/
├── agent.md          # 主配置（行为指导）
└── tools.json        # 工具优先级配置（可选）
```

2. **agent.md 内容**
```markdown
# Kimi Agent 配置

你是一个主动、积极的 AI 助手，类似于 Claude Code。

## 核心原则

1. **先尝试，再说明** - 不要过早说"我无法..."，先尝试使用工具
2. **展示过程** - 使用工具时，告诉用户"正在查询..."
3. **失败后解释** - 只有工具调用失败后，才说明原因

## 工具使用策略

### 联网查询（WebSearch, WebFetch）
- 用户问天气、新闻、实时信息 → **立即使用 WebSearch**
- 用户提供 URL → **立即使用 WebFetch**
- **格式：** "正在搜索..." → 展示结果 / "搜索失败：[原因]"

### 文件操作（Read, Write, Edit）
- 用户说"创建文件" → **立即使用 Write**
- 用户说"查看文件" → **立即使用 Read**
- **格式：** "正在创建..." → 完成 / "创建失败：[原因]"

### 命令执行（Bash）
- 用户问"当前目录" → **立即使用 ls 或 pwd**
- 用户说"运行测试" → **立即使用相应命令**
- **格式：** "正在执行..." → 展示输出 / "执行失败：[原因]"

## 禁止的回答模式

❌ "我没有实时天气数据源"
❌ "我无法查询..."
❌ "你可以自己去..."

✅ "正在搜索大连天气..."
✅ "让我查询一下..."
✅ "正在获取信息..."
```

3. **工具描述增强**

在创建 ExternalTool 时，在 description 中加入使用指导：

```typescript
// src/runtime/networkGateway.ts
{
  name: "web.search",
  description: `搜索互联网信息。

**使用场景：** 天气、新闻、实时信息、最新技术文档等
**行为要求：**
- 用户询问实时信息时，立即使用此工具
- 先显示"正在搜索..."，再返回结果
- 不要说"我无法查询"，直接尝试`,
  parameters: {...}
}
```

**成本：** 低
**收益：** 中高
**风险：** 低

---

### 方案 B：全局配置文件

**原理：** 在用户目录创建全局配置，影响所有 Kimi 会话

**位置：** `~/.kimi/config/agent.md`

**优点：**
- ✅ 一次配置，全局生效
- ✅ 用户可以自定义

**缺点：**
- ❌ 影响所有项目（可能不想要）
- ❌ 需要修改 Swift 代码来加载全局配置

**成本：** 中
**收益：** 高
**风险：** 中

---

### 方案 C：工具拦截层

**原理：** 在 Swift 层拦截工具调用，添加"正在执行..."提示

**实现：**

```swift
// macos/Sources/KimiAgentCore/ToolInterceptor.swift
public class ToolInterceptor {
    func beforeToolCall(tool: String, args: Any) {
        let message = makeProgressMessage(tool: tool)
        // 显示 "正在搜索..."
        emitProgress(message)
    }

    func makeProgressMessage(tool: String) -> String {
        switch tool {
        case "web.search": return "正在搜索..."
        case "web.fetch": return "正在获取网页..."
        case "bash": return "正在执行命令..."
        case "read": return "正在读取文件..."
        case "write", "edit": return "正在写入文件..."
        default: return "正在执行..."
        }
    }
}
```

**优点：**
- ✅ 强制展示过程
- ✅ 用户体验一致

**缺点：**
- ❌ 不解决"不主动使用工具"问题
- ❌ 只是 UI 层面的改进

**成本：** 中
**收益：** 低
**风险：** 低

---

### 方案 D：Prompt 前置包装

**原理：** 在用户消息发送到 Kimi 之前，自动附加行为指导

**实现：**

```swift
// macos/Sources/KimiAgentDesktop/DesktopAppModel.swift
func submitComposerPrompt() {
    let userPrompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

    // 检测意图
    let intent = detectIntent(userPrompt)

    // 包装 prompt
    let enhancedPrompt: String
    if intent == .webQuery {
        enhancedPrompt = """
        用户问题：\(userPrompt)

        行为要求：立即使用 WebSearch 工具搜索。不要说"我无法查询"，直接搜索。
        """
    } else {
        enhancedPrompt = userPrompt
    }

    // 发送增强后的 prompt
    startTask(task, promptOverride: enhancedPrompt)
}

func detectIntent(_ prompt: String) -> Intent {
    let lowerPrompt = prompt.lowercased()
    if lowerPrompt.contains("天气") || lowerPrompt.contains("新闻") {
        return .webQuery
    }
    // 更多检测...
    return .general
}
```

**优点：**
- ✅ 直接影响 Kimi 行为
- ✅ 可以针对不同意图定制

**缺点：**
- ❌ 需要维护意图识别逻辑
- ❌ 可能误判

**成本：** 高
**收益：** 高
**风险：** 中

---

## 推荐方案：A + C 组合

### 实施步骤

#### 阶段 1：项目配置文件（立即实施）

1. 创建 `.kimi/agent.md` 模板
2. 在应用启动时，检查并创建模板
3. 用户可以编辑定制

**代码位置：**
- 模板：`resources/templates/agent.md`
- 创建逻辑：`DesktopAppModel.swift` 初始化时

#### 阶段 2：工具描述增强（立即实施）

1. 修改 `src/runtime/networkGateway.ts`
2. 在每个工具的 description 中添加行为指导
3. 重新编译

#### 阶段 3：工具拦截层（可选，提升体验）

1. 创建 `ToolInterceptor.swift`
2. 在工具调用前显示进度提示
3. 提升用户体验

### 预期效果

**优化前：**
```
用户: 大连天气如何
Kimi: 目前我没有可用的实时天气数据源...
```

**优化后：**
```
用户: 大连天气如何
Kimi: 正在搜索大连天气...
     [调用 WebSearch]
     根据最新信息，大连今天...
```

---

## 实施优先级

### 第一优先级（立即实施）✅
1. 创建 `.kimi/agent.md` 配置模板
2. 增强工具描述（networkGateway.ts）

### 第二优先级（本周内）
3. 实现工具拦截层（显示进度）
4. 添加全局配置支持

### 第三优先级（长期优化）
5. 意图识别和 Prompt 包装
6. 基于用户反馈持续调优

---

## 风险评估

| 风险 | 概率 | 影响 | 缓解措施 |
|------|------|------|----------|
| 配置文件不生效 | 中 | 高 | 提供测试工具，验证加载 |
| 工具描述过长 | 低 | 低 | 控制在合理长度 |
| 行为过于激进 | 中 | 中 | 用户可以编辑配置文件 |
| Kimi 仍然不用工具 | 高 | 高 | 需要测试，可能需要方案 D |

---

## 总结

**最佳路径：**
1. 先实施**方案 A**（项目配置）+ 工具描述增强
2. 测试效果
3. 如果效果不够，追加**方案 C**（工具拦截）或**方案 D**（Prompt 包装）

**预计工作量：**
- 方案 A：2-3 小时
- 工具描述增强：1 小时
- 方案 C（可选）：3-4 小时
- 方案 D（可选）：5-6 小时

**成功标准：**
- ✅ 用户问天气，Kimi 主动搜索
- ✅ 显示"正在搜索..."过程
- ✅ 不再说"我无法..."

立即开始实施吗？
