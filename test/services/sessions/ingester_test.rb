require "test_helper"

class Sessions::IngesterTest < ActiveSupport::TestCase
  test "ingests a Claude Code transcript into the normalized schema" do
    with_agent_homes do |homes|
      claude_history(homes[:claude_home], [ TranscriptFixtures::PROJECT_DIR ])
      path = write_claude_transcript(homes[:claude_home], claude_lines)

      result = Sessions::Ingester.call(path)
      assert_equal :succeeded, result.status

      session = Session.find(TranscriptFixtures::CLAUDE_SESSION_ID)
      assert_equal "claude_code", session.source
      assert_equal TranscriptFixtures::PROJECT_DIR, session.directory
      assert_equal TranscriptFixtures::ENCODED_PROJECT, session.project_path
      assert_nil session.worktree
      assert_equal "main", session.branch
      assert_equal "check the repo state", session.first_prompt
      assert_equal 1, session.user_message_count
      assert_equal 1, session.assistant_message_count
      assert_equal 4200, session.active_duration_ms

      block = ContentBlock.find_by(tool_name: "Bash")
      assert_equal "shell", block.tool_kind
      assert_equal "git status", block.bash_command
      assert_equal [ "git" ], block.bash_programs
    end
  end

  test "ingests a Codex rollout into the same schema" do
    with_agent_homes do |homes|
      path = write_codex_transcript(homes[:codex_home], codex_lines)

      result = Sessions::Ingester.call(path)
      assert_equal :succeeded, result.status

      session = Session.find(TranscriptFixtures::CODEX_THREAD_ID)
      assert_equal "codex", session.source
      assert_equal TranscriptFixtures::PROJECT_DIR, session.directory
      assert_equal "main", session.branch
      assert_equal "check the repo state", session.first_prompt
      assert_equal 1, session.user_message_count
      assert_equal 4200, session.active_duration_ms
    end
  end

  test "a Codex shell call lands in the same queryable columns as a Bash call" do
    with_agent_homes do |homes|
      Sessions::Ingester.call(write_codex_transcript(homes[:codex_home], codex_lines))

      block = ContentBlock.find_by(tool_name: "shell")
      assert_equal "shell", block.tool_kind
      # The `bash -lc` wrapper is stripped, so the command reads the same way a
      # Claude Code Bash call does.
      assert_equal "git status", block.bash_command
      assert_equal [ "git" ], block.bash_programs
    end
  end

  test "attributes Codex token usage and cost to the assistant turn" do
    with_agent_homes do |homes|
      Sessions::Ingester.call(write_codex_transcript(homes[:codex_home], codex_lines))

      message = AssistantMessage.joins(:message)
                                .where(messages: { session_id: TranscriptFixtures::CODEX_THREAD_ID })
                                .order(:cost_usd).last

      assert_equal "gpt-5.3-codex", message.model
      assert_equal "resp_1", message.api_message_id
      # input_tokens is reported inclusive of the cached portion.
      assert_equal 600, message.input_tokens
      assert_equal 400, message.cache_read_input_tokens
      assert_equal 100, message.cache_creation_input_tokens
      assert_equal 200, message.output_tokens

      expected = (600 * 1.75 + 400 * 0.175 + 200 * 14.0) / 1_000_000.0
      assert_in_delta expected, message.cost_usd.to_f, 1e-9
    end
  end

  test "groups a Codex model response into one assistant message" do
    with_agent_homes do |homes|
      Sessions::Ingester.call(write_codex_transcript(homes[:codex_home], codex_lines))

      messages = Message.where(session_id: TranscriptFixtures::CODEX_THREAD_ID)
      # The reasoning and the shell call share one assistant message; the final
      # answer is a second one, after the tool result broke the run.
      assert_equal 2, messages.where(message_type: :assistant).count
      assert_equal 1, messages.where(message_type: :tool_result).count

      first = AssistantMessage.joins(:message)
                              .where(messages: { session_id: TranscriptFixtures::CODEX_THREAD_ID })
                              .order("messages.timestamp").first
      assert_equal %w[thinking tool_use], first.content_blocks.order(:position).map(&:block_type)
    end
  end

  test "re-ingesting an unchanged file is skipped" do
    with_agent_homes do |homes|
      path = write_claude_transcript(homes[:claude_home], claude_lines)

      assert_equal :succeeded, Sessions::Ingester.call(path).status
      assert_equal :skipped, Sessions::Ingester.call(path).status
    end
  end

  test "re-reading a Codex rollout in full does not duplicate rows" do
    with_agent_homes do |homes|
      path = write_codex_transcript(homes[:codex_home], codex_lines)
      Sessions::Ingester.call(path)
      before = Message.where(session_id: TranscriptFixtures::CODEX_THREAD_ID).count

      # Codex files are never resumed from an offset, so touching the file
      # forces the whole transcript through the upserts a second time.
      SessionFile.find_by(file_path: path).update!(file_mtime: 1.day.ago)
      assert_equal :succeeded, Sessions::Ingester.call(path).status

      assert_equal before, Message.where(session_id: TranscriptFixtures::CODEX_THREAD_ID).count
    end
  end

  test "picks up new lines appended to a Claude transcript" do
    with_agent_homes do |homes|
      path = write_claude_transcript(homes[:claude_home], claude_lines)
      Sessions::Ingester.call(path)

      File.open(path, "a") do |file|
        file.puts(JSON.generate(
                    "type" => "user", "uuid" => "aaaa1111-0000-0000-0000-000000000005",
                    "timestamp" => "2026-08-31T10:01:00.000Z",
                    "message" => { "content" => "and now the diff" }
                  ))
      end

      assert_equal :succeeded, Sessions::Ingester.call(path).status
      assert_equal 2, Session.find(TranscriptFixtures::CLAUDE_SESSION_ID).user_message_count
    end
  end

  test "records both agents' sessions side by side" do
    with_agent_homes do |homes|
      claude_history(homes[:claude_home], [ TranscriptFixtures::PROJECT_DIR ])
      Sessions::Ingester.call(write_claude_transcript(homes[:claude_home], claude_lines))
      Sessions::Ingester.call(write_codex_transcript(homes[:codex_home], codex_lines))

      assert_equal 1, Session.claude_code.count
      assert_equal 1, Session.codex.count
      assert_equal [ TranscriptFixtures::PROJECT_DIR ], Session.directories
    end
  end

  test "survives a NUL character that Postgres would reject" do
    with_agent_homes do |homes|
      lines = claude_lines
      lines[1]["message"]["content"][1]["input"]["command"] = "grep \u0000 binary.bin"
      lines[1]["message"]["content"][0]["thinking"] = "before\u0000after"
      path = write_claude_transcript(homes[:claude_home], lines)

      assert_equal :succeeded, Sessions::Ingester.call(path).status

      block = ContentBlock.find_by(tool_name: "Bash")
      assert_equal "grep  binary.bin", block.tool_input["command"]
      assert_equal "beforeafter", ContentBlock.find_by(block_type: :thinking).text_content
    end
  end

  test "treats harness-injected context as meta, not as a user prompt" do
    with_agent_homes do |homes|
      path = install_real_codex_rollout(homes[:codex_home])
      assert_equal :succeeded, Sessions::Ingester.call(path).status

      session = Session.find(TranscriptFixtures::REAL_CODEX_THREAD_ID)
      prompts = UserPrompt.joins(:message)
                          .where(messages: { session_id: session.session_id })
                          .order("messages.timestamp")

      # Three developer messages plus AGENTS.md, which Codex sends with role
      # "user" -- only the last prompt was actually typed by the operator.
      assert_equal [ true, true, true, true, false ], prompts.map(&:is_meta)
      assert_equal 1, session.user_message_count
      assert_match(/\AI want you to create a new directory/, session.first_prompt)
      assert_match(/\AI want you to create a new directory/, session.title)
    end
  end

  test "reads usage from token_count events when there are no usage records" do
    with_agent_homes do |homes|
      path = install_real_codex_rollout(homes[:codex_home])
      Sessions::Ingester.call(path)

      session = Session.find(TranscriptFixtures::REAL_CODEX_THREAD_ID)
      # Matches the final cumulative `total_token_usage` in the transcript.
      assert_equal 125_166, session.total_input_tokens
      assert_equal 114_688, session.total_cache_read_tokens
      assert_equal 1_033, session.total_output_tokens

      # gpt-5.6-terra: $2 fresh input, $0.20 cached, $12 output per million.
      # The session total sums eight per-turn costs, each already rounded to
      # the column's six decimals, so it can drift slightly from computing the
      # whole thing in one go.
      fresh = 125_166 - 114_688
      expected = (fresh * 2.0 + 114_688 * 0.2 + 1_033 * 12.0) / 1_000_000.0
      assert_in_delta expected, session.total_cost_usd.to_f, 1e-5
    end
  end

  test "reads turn duration from task_complete as well as turn_complete" do
    with_agent_homes do |homes|
      path = install_real_codex_rollout(homes[:codex_home])
      Sessions::Ingester.call(path)

      assert_equal 30_304, Session.find(TranscriptFixtures::REAL_CODEX_THREAD_ID).active_duration_ms
    end
  end

  test "lifts shell commands out of a Code Mode program" do
    with_agent_homes do |homes|
      Sessions::Ingester.call(install_real_codex_rollout(homes[:codex_home]))

      blocks = ContentBlock.joins(assistant_message: :message)
                           .where(messages: { session_id: TranscriptFixtures::REAL_CODEX_THREAD_ID })
                           .where(tool_kind: "shell").order(:id)

      # The command lives inside `tools.exec_command({...})` in a JavaScript
      # program, but lands in the same columns a Claude Bash call would.
      assert_equal 6, blocks.count
      assert_match(/\Apwd && rg --files/, blocks.first.bash_command)
      assert_equal %w[pwd rg], blocks.first.bash_programs
      assert_equal [ "exec_command" ], blocks.first.tool_input["tools"]
      # The program itself is kept, so the extraction loses nothing.
      assert_match(/tools\.exec_command/, blocks.first.tool_input["program"])
    end
  end

  test "counts files edited by a Code Mode apply_patch" do
    with_agent_homes do |homes|
      Sessions::Ingester.call(install_real_codex_rollout(homes[:codex_home]))

      block = ContentBlock.joins(assistant_message: :message)
                          .where(messages: { session_id: TranscriptFixtures::REAL_CODEX_THREAD_ID })
                          .find_by(tool_kind: "edit")

      assert_equal "funny-joke/README.md", block.tool_input["file_path"]
      assert_equal [ "apply_patch" ], block.tool_input["tools"]
      assert_equal 1, Session.find(TranscriptFixtures::REAL_CODEX_THREAD_ID).files_edited_count
    end
  end

  test "records every program in a chained shell command" do
    with_agent_homes do |homes|
      lines = claude_lines
      lines[1]["message"]["content"][1]["input"]["command"] =
        "find . -type f | sort | head -5; git status && echo done"
      Sessions::Ingester.call(write_claude_transcript(homes[:claude_home], lines))

      # Regression guard: the separator pattern was once double-escaped, which
      # silently reduced this to just the first program.
      assert_equal %w[find sort head git echo],
                   ContentBlock.find_by(tool_name: "Bash").bash_programs
    end
  end

  test "a session opened with a slash command is named after the real request" do
    with_agent_homes do |homes|
      lines = claude_lines
      opener = {
        "type" => "user", "uuid" => "aaaa1111-0000-0000-0000-0000000000ff",
        "timestamp" => "2026-08-31T09:59:00.000Z", "cwd" => TranscriptFixtures::PROJECT_DIR,
        "message" => { "content" => "<command-name>/clear</command-name>\n" \
                                    "<command-message>clear</command-message>\n" \
                                    "<command-args></command-args>" }
      }
      subagent = {
        "type" => "user", "uuid" => "aaaa1111-0000-0000-0000-0000000000fe",
        "timestamp" => "2026-08-31T09:59:30.000Z", "isSidechain" => true,
        "cwd" => TranscriptFixtures::PROJECT_DIR,
        "message" => { "content" => "search the repo for every call site" }
      }
      Sessions::Ingester.call(
        write_claude_transcript(homes[:claude_home], [ opener, subagent ] + claude_lines)
      )

      session = Session.find(TranscriptFixtures::CLAUDE_SESSION_ID)
      # `first_prompt` still means the first prompt, verbatim...
      assert session.first_prompt.start_with?("<command-name>/clear</command-name>")
      # ...but the name comes from the first prompt worth naming it after, and
      # a subagent's prompt is not the session's subject.
      assert_equal "check the repo state", session.title_prompt
      assert_equal "check the repo state", session.title
    end
  end

  test "a session with nothing said in it falls back to a short id" do
    with_agent_homes do |homes|
      lines = claude_lines.reject { |line| line["type"] == "user" }
      Sessions::Ingester.call(write_claude_transcript(homes[:claude_home], lines))

      session = Session.find(TranscriptFixtures::CLAUDE_SESSION_ID)
      assert_nil session.title_prompt
      assert_equal "Session #{TranscriptFixtures::CLAUDE_SESSION_ID[0, 8]}", session.title
    end
  end

  test "an agent-set custom title outranks anything derived" do
    with_agent_homes do |homes|
      lines = claude_lines + [ { "type" => "custom-title", "customTitle" => "Repo triage" } ]
      Sessions::Ingester.call(write_claude_transcript(homes[:claude_home], lines))

      assert_equal "Repo triage", Session.find(TranscriptFixtures::CLAUDE_SESSION_ID).title
    end
  end

  test "a file under no known agent directory is reported as unsupported" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "somewhere.jsonl")
      File.write(path, "{}\n")

      assert_equal :unsupported, Sessions::Ingester.call(path).status
    end
  end
end
