import Foundation

/// Renders a conversation into the exact prompt text Qwen3.5 expects.
///
/// This is a hand-port of the `tokenizer.chat_template` embedded in
/// `Qwen3.5-4B-Q4_K_M.gguf` (text paths only — no image/video parts). Porting it
/// instead of running a Jinja engine keeps the hot path allocation-light and lets
/// us unit-test every branch against strings captured from the reference template.
///
/// Two rendering modes:
/// - `.canonical` — byte-for-byte what the template produces. Past assistant turns
///   lose their `<think>` blocks (the template strips reasoning from history).
/// - `.verbatim` — past assistant turns that carry `rawCompletion` are replayed
///   exactly as generated. The prompt then extends what is already in the model's
///   state, so a new turn costs only the new suffix instead of a full re-prefill.
///   (Qwen3.5 is a hybrid recurrent model: its state cannot be rolled back to an
///   arbitrary token, so an append-only prompt is the difference between ~50 ms
///   and several seconds per turn on a phone.)
public enum PromptBuilder {
    public enum Mode: Sendable { case canonical, verbatim }

    public static let imStart = "<|im_start|>"
    public static let imEnd = "<|im_end|>"

    /// The generation prompt suffix that follows `<|im_start|>assistant\n`.
    public static func generationPrefix(thinking: Bool) -> String {
        thinking ? "<think>\n" : "<think>\n\n</think>\n\n"
    }

    public static func render(
        _ messages: [ChatMessage],
        tools: [ToolSpec] = [],
        addGenerationPrompt: Bool = true,
        enableThinking: Bool = false,
        mode: Mode = .canonical
    ) -> String {
        precondition(!messages.isEmpty, "No messages provided.")
        var out = ""

        // System block (with tools, if any).
        if !tools.isEmpty {
            out += "\(imStart)system\n"
            out += "# Tools\n\nYou have access to the following functions:\n\n<tools>"
            for tool in tools { out += "\n" + tool.templateJSON }
            out += "\n</tools>"
            out += toolInstructions
            if messages[0].role == .system {
                let content = trim(messages[0].content)
                if !content.isEmpty { out += "\n\n" + content }
            }
            out += "\(imEnd)\n"
        } else if messages[0].role == .system {
            out += "\(imStart)system\n" + trim(messages[0].content) + "\(imEnd)\n"
        }

        // Index of the last genuine user query (tool responses don't count).
        var lastQueryIndex = messages.count - 1
        var foundQuery = false
        for index in stride(from: messages.count - 1, through: 0, by: -1) where messages[index].role == .user {
            let content = trim(messages[index].content)
            if !(content.hasPrefix("<tool_response>") && content.hasSuffix("</tool_response>")) {
                lastQueryIndex = index
                foundQuery = true
                break
            }
        }
        precondition(foundQuery, "No user query found in messages.")

        for (index, message) in messages.enumerated() {
            let content = trim(message.content)
            switch message.role {
            case .system:
                precondition(index == 0, "System message must be at the beginning.")
            case .user:
                out += "\(imStart)user\n" + content + "\(imEnd)\n"
            case .assistant:
                if mode == .verbatim, let raw = message.rawCompletion {
                    out += "\(imStart)assistant\n" + raw + "\(imEnd)\n"
                    continue
                }
                out += renderAssistant(message, content: content, inCurrentTurn: index > lastQueryIndex, mode: mode)
            case .tool:
                if index > 0, messages[index - 1].role != .tool { out += "\(imStart)user" }
                out += "\n<tool_response>\n" + content + "\n</tool_response>"
                let isLast = index == messages.count - 1
                if isLast || messages[index + 1].role != .tool { out += "\(imEnd)\n" }
            }
        }

        if addGenerationPrompt {
            out += "\(imStart)assistant\n" + generationPrefix(thinking: enableThinking)
        }
        return out
    }

    private static func renderAssistant(_ message: ChatMessage, content rawContent: String, inCurrentTurn: Bool, mode: Mode) -> String {
        var content = rawContent
        var reasoning = message.reasoning ?? ""
        if message.reasoning == nil, content.contains("</think>") {
            let before = content.components(separatedBy: "</think>")[0]
            reasoning = String(before.components(separatedBy: "<think>").last ?? "")
                .trimmingCharacters(in: .init(charactersIn: "\n"))
            content = String(content.components(separatedBy: "</think>").last ?? "")
                .replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        }
        reasoning = trim(reasoning)

        var out = "\(imStart)assistant\n"
        if inCurrentTurn {
            out += "<think>\n" + reasoning + "\n</think>\n\n" + content
        } else if mode == .verbatim {
            // A history turn without a raw completion gets the empty think block a
            // non-thinking generation would have produced; its reasoning is dropped,
            // exactly as the canonical template drops it.
            out += "<think>\n\n</think>\n\n" + content
        } else {
            out += content
        }
        for (i, call) in message.toolCalls.enumerated() {
            if i == 0 {
                out += trim(content).isEmpty ? "<tool_call>\n<function=\(call.name)>\n" : "\n\n<tool_call>\n<function=\(call.name)>\n"
            } else {
                out += "\n<tool_call>\n<function=\(call.name)>\n"
            }
            for arg in call.arguments {
                out += "<parameter=\(arg.name)>\n" + arg.value + "\n</parameter>\n"
            }
            out += "</function>\n</tool_call>"
        }
        return out + "\(imEnd)\n"
    }

    /// Jinja's `|trim` (Python `str.strip()`).
    static func trim(_ s: String) -> String { s.trimmingCharacters(in: pythonWhitespace) }

    /// `str.isspace()` also treats the ASCII separators U+001C–U+001F as whitespace.
    static let pythonWhitespace: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}")
        return set
    }()

    /// Neutralises chat-control markers in untrusted text (user input, tool output)
    /// so it can't open or close turns: `<|im_end|>` becomes `<\u{200B}|im_end|>`.
    public static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "<|", with: "<\u{200B}|")
    }

    static let toolInstructions = """


If you choose to call a function ONLY reply in the following format with NO suffix:

<tool_call>
<function=example_function_name>
<parameter=example_parameter_1>
value_1
</parameter>
<parameter=example_parameter_2>
This is the value for the second parameter
that can span
multiple lines
</parameter>
</function>
</tool_call>

<IMPORTANT>
Reminder:
- Function calls MUST follow the specified format: an inner <function=...></function> block must be nested within <tool_call></tool_call> XML tags
- Required parameters MUST be specified
- You may provide optional reasoning for your function call in natural language BEFORE the function call, but NOT after
- If there is no function call available, answer the question like normal with your current knowledge and do not tell the user about function calls
</IMPORTANT>
"""
}
