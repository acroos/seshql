require "tmpdir"

# Writes throwaway agent session directories and points the adapters at them,
# so ingestion can be exercised end to end without touching the real
# `~/.claude` or `~/.codex` on the machine running the tests.
module TranscriptFixtures
  CLAUDE_SESSION_ID = "11111111-2222-3333-4444-555555555555".freeze
  CODEX_THREAD_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".freeze
  PROJECT_DIR = "/Users/test/dev/demo".freeze
  ENCODED_PROJECT = "-Users-test-dev-demo".freeze

  def with_agent_homes
    Dir.mktmpdir("seshql-transcripts") do |root|
      claude_home = File.join(root, "claude")
      codex_home = File.join(root, "codex")
      FileUtils.mkdir_p([ claude_home, codex_home ])

      with_env("CLAUDE_HOME" => claude_home, "CODEX_HOME" => codex_home) do
        Sessions::PathLookup.reset!
        yield(claude_home: claude_home, codex_home: codex_home)
      ensure
        Sessions::PathLookup.reset!
      end
    end
  end

  def write_claude_transcript(claude_home, lines, project: ENCODED_PROJECT, session_id: CLAUDE_SESSION_ID)
    dir = File.join(claude_home, "projects", project)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{session_id}.jsonl")
    write_jsonl(path, lines)
    path
  end

  def write_codex_transcript(codex_home, lines, thread_id: CODEX_THREAD_ID, at: "2026-08-31T10-00-00")
    date = at[0, 10].split("-")
    dir = File.join(codex_home, "sessions", *date)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "rollout-#{at}-#{thread_id}.jsonl")
    write_jsonl(path, lines)
    path
  end

  # A real Codex 0.151 rollout, trimmed and redacted. Kept alongside the
  # hand-built fixtures because that build differs from the current protocol in
  # ways only a real file reveals: `task_*` turn events instead of `turn_*`,
  # usage in `token_count` events instead of `token_usage_record` lines, and
  # AGENTS.md injected with role "user".
  REAL_CODEX_THREAD_ID = "01a05a0b-750b-7842-89ec-393acd3667db".freeze

  def install_real_codex_rollout(codex_home)
    name = "rollout-2026-08-31T15-58-15-#{REAL_CODEX_THREAD_ID}.jsonl"
    dir = File.join(codex_home, "sessions", "2026", "08", "31")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, name)
    FileUtils.cp(Rails.root.join("test/fixtures/files/codex", name), dest)
    dest
  end

  def claude_history(claude_home, mapping)
    path = File.join(claude_home, "history.jsonl")
    write_jsonl(path, mapping.map { |project| { "project" => project } })
    Sessions::PathLookup.reset!
    path
  end

  # A minimal but complete Claude Code session: a prompt, one assistant turn
  # that shells out, the tool result, and the turn-duration event.
  def claude_lines
    assistant_uuid = "aaaa1111-0000-0000-0000-000000000002"
    [
      {
        "type" => "user", "uuid" => "aaaa1111-0000-0000-0000-000000000001",
        "timestamp" => "2026-08-31T10:00:00.000Z", "cwd" => PROJECT_DIR,
        "gitBranch" => "main", "version" => "2.0.0",
        "message" => { "content" => "check the repo state" }
      },
      {
        "type" => "assistant", "uuid" => assistant_uuid,
        "parentUuid" => "aaaa1111-0000-0000-0000-000000000001",
        "timestamp" => "2026-08-31T10:00:05.000Z", "cwd" => PROJECT_DIR,
        "gitBranch" => "main",
        "message" => {
          "id" => "msg_1", "model" => "claude-opus-5", "stop_reason" => "tool_use",
          "usage" => {
            "input_tokens" => 600, "output_tokens" => 200,
            "cache_creation_input_tokens" => 100, "cache_read_input_tokens" => 400
          },
          "content" => [
            { "type" => "thinking", "thinking" => "Let me look.", "signature" => "sig" },
            { "type" => "tool_use", "id" => "toolu_1", "name" => "Bash",
              "input" => { "command" => "git status" } }
          ]
        }
      },
      {
        "type" => "user", "uuid" => "aaaa1111-0000-0000-0000-000000000003",
        "timestamp" => "2026-08-31T10:00:06.000Z",
        "sourceToolAssistantUUID" => assistant_uuid,
        "message" => {
          "content" => [ { "type" => "tool_result", "tool_use_id" => "toolu_1",
                           "content" => "On branch main" } ]
        }
      },
      {
        "type" => "system", "uuid" => "aaaa1111-0000-0000-0000-000000000004",
        "timestamp" => "2026-08-31T10:00:07.000Z",
        "subtype" => "turn_duration", "durationMs" => 4200
      }
    ]
  end

  # The Codex equivalent of `claude_lines`, in rollout form.
  def codex_lines
    [
      { "timestamp" => "2026-08-31T10:00:00.000Z", "ordinal" => 1, "type" => "session_meta",
        "payload" => {
          "id" => CODEX_THREAD_ID, "session_id" => CODEX_THREAD_ID,
          "timestamp" => "2026-08-31T10:00:00.000Z", "cwd" => PROJECT_DIR,
          "originator" => "codex_cli_rs", "cli_version" => "0.52.0", "source" => "cli",
          "model_provider" => "openai", "history_mode" => "legacy",
          "git" => { "branch" => "main", "commit_hash" => "abc123",
                     "repository_url" => "https://github.com/test/demo" }
        } },
      { "timestamp" => "2026-08-31T10:00:01.000Z", "ordinal" => 2, "type" => "turn_context",
        "payload" => { "turn_id" => "turn-1", "cwd" => PROJECT_DIR,
                       "model" => "gpt-5.3-codex", "effort" => "medium",
                       "approval_policy" => "on-request",
                       "sandbox_policy" => { "mode" => "workspace-write" },
                       "summary" => "auto" } },
      { "timestamp" => "2026-08-31T10:00:02.000Z", "ordinal" => 3, "type" => "response_item",
        "payload" => { "type" => "message", "role" => "user",
                       "content" => [ { "type" => "input_text", "text" => "check the repo state" } ] } },
      { "timestamp" => "2026-08-31T10:00:03.000Z", "ordinal" => 4, "type" => "response_item",
        "payload" => { "type" => "reasoning", "id" => "rs_1",
                       "summary" => [ { "type" => "summary_text", "text" => "Let me look." } ],
                       "encrypted_content" => "sig" } },
      { "timestamp" => "2026-08-31T10:00:04.000Z", "ordinal" => 5, "type" => "response_item",
        "payload" => { "type" => "function_call", "id" => "fc_1", "name" => "shell",
                       "arguments" => '{"command":["bash","-lc","git status"]}',
                       "call_id" => "call_1" } },
      { "timestamp" => "2026-08-31T10:00:05.000Z", "ordinal" => 6, "type" => "token_usage_record",
        "payload" => { "thread_id" => CODEX_THREAD_ID, "turn_id" => "turn-1",
                       "session_id" => CODEX_THREAD_ID, "root_turn_id" => "turn-1",
                       "response_id" => "resp_1",
                       "usage" => { "input_tokens" => 1000, "cached_input_tokens" => 400,
                                    "cache_write_input_tokens" => 100, "output_tokens" => 200,
                                    "reasoning_output_tokens" => 50, "total_tokens" => 1200 } } },
      { "timestamp" => "2026-08-31T10:00:06.000Z", "ordinal" => 7, "type" => "response_item",
        "payload" => { "type" => "function_call_output", "call_id" => "call_1",
                       "output" => "On branch main" } },
      { "timestamp" => "2026-08-31T10:00:07.000Z", "ordinal" => 8, "type" => "response_item",
        "payload" => { "type" => "message", "role" => "assistant",
                       "content" => [ { "type" => "output_text", "text" => "Done." } ] } },
      { "timestamp" => "2026-08-31T10:00:08.000Z", "ordinal" => 9, "type" => "event_msg",
        "payload" => { "type" => "turn_complete", "turn_id" => "turn-1",
                       "last_agent_message" => "Done.", "duration_ms" => 4200 } }
    ]
  end

  private

  def write_jsonl(path, lines)
    File.write(path, lines.map { |line| "#{JSON.generate(line)}\n" }.join)
  end

  def with_env(values)
    previous = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
