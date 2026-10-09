import Foundation
import HarnessCore

/// Runs the LLM judge (`Judge`) over the replies of a run with a cheap text model
/// (Chat Completions, JSON output, temperature 0). The key is read by the caller
/// (`KeyFile`) and only ever goes into the Authorization header.
public struct JudgeClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public var model: String
    private let key: String
    private let transport: Transport
    public var endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    /// Requests in flight at once.
    public var parallel = 4

    public init(model: String = Judge.defaultModel, key: String,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.model = model
        self.key = key
        self.transport = transport
    }

    /// Scores every item (failures are listed, not fatal). `maxUSD` stops early.
    public func judge(_ items: [Judge.Item], maxUSD: Double = 0.50, log: @escaping @Sendable (String) -> Void = { _ in })
        async -> Judge.Summary {
        var summary = Judge.Summary(model: model)
        var index = 0
        while index < items.count {
            if Judge.dollars(summary) > maxUSD {
                summary.failures.append("stopped: judge spend over $\(maxUSD)")
                break
            }
            let batch = Array(items[index..<min(index + parallel, items.count)])
            index += batch.count
            let results = await withTaskGroup(of: (Int, Result<(Judge.Score, Int, Int), Error>).self) { group in
                for (k, item) in batch.enumerated() {
                    group.addTask { (k, await self.score(item)) }
                }
                var out: [(Int, Result<(Judge.Score, Int, Int), Error>)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }
            }
            for (k, r) in results {
                switch r {
                case .success(let (score, input, output)):
                    summary.scores.append(score)
                    summary.usageInputTokens += input
                    summary.usageOutputTokens += output
                    log("judge \(score.scenario)#\(score.index) \(score.fixture): \(score.score) \(score.reason)")
                case .failure(let e):
                    let item = batch[k]
                    summary.failures.append("\(item.scenario)#\(item.index): \(Redact.secrets("\(e)"))")
                }
            }
        }
        summary.aggregate()
        return summary
    }

    func score(_ item: Judge.Item) async -> Result<(Judge.Score, Int, Int), Error> {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: Judge.requestBody(item, model: model))
            var lastError: Error = Judge.ParseError(description: "no attempt")
            for attempt in 0..<3 {
                if attempt > 0 { try await Task.sleep(for: .seconds(Double(attempt) * 2)) }
                do {
                    let (data, response) = try await transport(request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                    if status == 429 || status >= 500 { lastError = Judge.ParseError(description: "HTTP \(status)"); continue }
                    let (content, input, output) = try Judge.content(ofResponse: data)
                    return .success((try Judge.parse(content, item: item), input, output))
                } catch {
                    lastError = error
                }
            }
            return .failure(lastError)
        } catch {
            return .failure(error)
        }
    }
}
