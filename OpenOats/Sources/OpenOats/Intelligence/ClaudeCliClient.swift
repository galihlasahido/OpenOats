import Foundation
import os

/// LLM client that shells out to the Claude Code CLI (`claude -p`).
/// Supports both non-streaming (complete) and streaming (line-by-line) modes.
actor ClaudeCliClient {
    private let log = Logger(subsystem: "com.openoats", category: "ClaudeCliClient")

    struct Message: Sendable {
        let role: String
        let content: String
    }

    /// Find the claude CLI binary path.
    private func claudePath() -> String? {
        // Common installation paths
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try `which claude` as fallback
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        return nil
    }

    /// Non-streaming completion: sends messages to `claude -p` and returns the full response.
    func complete(
        messages: [Message],
        maxTokens: Int = 512
    ) async throws -> String {
        guard let path = claudePath() else {
            throw ClaudeCliError.notFound
        }

        // Build the prompt from messages
        let prompt = buildPrompt(from: messages)

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-p", "--output-format", "text"]

            // Pass prompt via stdin
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Inherit PATH so claude can find its dependencies
            var env = ProcessInfo.processInfo.environment
            let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "\(NSHomeDirectory())/.local/bin"]
            let currentPath = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
            process.environment = env

            do {
                try process.run()

                // Write prompt to stdin and close
                let promptData = prompt.data(using: .utf8) ?? Data()
                stdinPipe.fileHandleForWriting.write(promptData)
                stdinPipe.fileHandleForWriting.closeFile()

                // Read output in background
                Task.detached {
                    process.waitUntilExit()
                    let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if process.terminationStatus != 0 {
                        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                        continuation.resume(throwing: ClaudeCliError.processFailed(
                            status: process.terminationStatus,
                            stderr: errorOutput
                        ))
                    } else if output.isEmpty {
                        continuation.resume(throwing: ClaudeCliError.emptyResponse)
                    } else {
                        continuation.resume(returning: output)
                    }
                }
            } catch {
                continuation.resume(throwing: ClaudeCliError.launchFailed(error))
            }
        }
    }

    /// Streaming completion: yields text line by line as claude produces output.
    func streamCompletion(
        messages: [Message],
        maxTokens: Int = 1024
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // For streaming, we use the same approach but yield line by line
                    let result = try await complete(messages: messages, maxTokens: maxTokens)
                    // Yield the full result (claude CLI doesn't support true streaming via -p)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Build a single prompt string from system/user/assistant messages.
    private func buildPrompt(from messages: [Message]) -> String {
        var parts: [String] = []
        for message in messages {
            switch message.role {
            case "system":
                parts.append("[System Instructions]\n\(message.content)")
            case "user":
                parts.append(message.content)
            case "assistant":
                parts.append("[Previous Response]\n\(message.content)")
            default:
                parts.append(message.content)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    enum ClaudeCliError: LocalizedError {
        case notFound
        case launchFailed(Error)
        case processFailed(status: Int32, stderr: String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .notFound:
                "Claude CLI not found. Install it from https://claude.ai/code"
            case .launchFailed(let error):
                "Failed to launch Claude CLI: \(error.localizedDescription)"
            case .processFailed(_, let stderr):
                "Claude CLI error: \(stderr.prefix(200))"
            case .emptyResponse:
                "Claude CLI returned an empty response."
            }
        }
    }
}
