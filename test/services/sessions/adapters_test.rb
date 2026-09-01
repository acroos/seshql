require "test_helper"

class Sessions::AdaptersTest < ActiveSupport::TestCase
  test "routes a file to the agent that owns its directory" do
    with_agent_homes do |homes|
      claude = write_claude_transcript(homes[:claude_home], claude_lines)
      codex = write_codex_transcript(homes[:codex_home], codex_lines)

      assert_equal Sessions::Adapters::ClaudeCode, Sessions::Adapters.for_path(claude)
      assert_equal Sessions::Adapters::Codex, Sessions::Adapters.for_path(codex)
    end
  end

  test "ignores files outside every agent directory" do
    with_agent_homes do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "notes.jsonl")
        File.write(path, "{}\n")

        assert_nil Sessions::Adapters.for_path(path)
      end
    end
  end

  test "discovers transcripts across both agents" do
    with_agent_homes do |homes|
      claude = write_claude_transcript(homes[:claude_home], claude_lines)
      codex = write_codex_transcript(homes[:codex_home], codex_lines)

      assert_equal [ claude, codex ].sort, Sessions::Adapters.discover.sort
    end
  end

  test "derives the session id from the path without opening the file" do
    assert_equal "abc-123",
                 Sessions::Adapters::ClaudeCode.session_id_for("/x/projects/-a-b/abc-123.jsonl")
    assert_equal TranscriptFixtures::CODEX_THREAD_ID,
                 Sessions::Adapters::Codex.session_id_for(
                   "rollout-2026-08-31T10-00-00-#{TranscriptFixtures::CODEX_THREAD_ID}.jsonl"
                 )
  end

  # A reverted Codex thread keeps its thread id and appends a distinct rollout
  # id, and both files belong to the same session.
  test "maps a reverted Codex rollout back to its original thread" do
    thread = TranscriptFixtures::CODEX_THREAD_ID
    name = "rollout-2026-08-31T10-00-00-#{thread}_99999999-8888-7777-6666-555555555555.jsonl"

    assert_equal thread, Sessions::Adapters::Codex.session_id_for(name)
  end

  test "recognizes compressed Codex rollouts and refuses to resume them" do
    name = "rollout-2026-08-31T10-00-00-#{TranscriptFixtures::CODEX_THREAD_ID}.jsonl.zst"

    assert Sessions::Adapters::Codex.transcript?(name)
    assert Sessions::Adapters::Codex.compressed?(name)
    assert_not Sessions::Adapters::Codex.resumable?(name)
  end

  test "a Claude worktree session keeps the base directory and names the worktree" do
    with_agent_homes do |homes|
      project = "#{TranscriptFixtures::ENCODED_PROJECT}--claude-worktrees-my-feature"
      claude_history(homes[:claude_home], [ TranscriptFixtures::PROJECT_DIR ])
      path = write_claude_transcript(homes[:claude_home], claude_lines,
                                     project: project, session_id: "cccccccc-0000-0000-0000-000000000000")

      Sessions::Ingester.call(path)
      session = Session.find("cccccccc-0000-0000-0000-000000000000")

      assert_equal TranscriptFixtures::PROJECT_DIR, session.directory
      assert_equal "my-feature", session.worktree
    end
  end

  test "maps each agent's tools onto a shared kind" do
    assert_equal "shell", Sessions::Adapters::ClaudeCode.tool_kind("Bash")
    assert_equal "shell", Sessions::Adapters::Codex.tool_kind("shell")
    assert_equal "edit", Sessions::Adapters::ClaudeCode.tool_kind("Edit")
    assert_equal "edit", Sessions::Adapters::Codex.tool_kind("apply_patch")
    assert_equal "mcp", Sessions::Adapters::ClaudeCode.tool_kind("mcp__linear__create_issue")
    assert_equal "mcp", Sessions::Adapters::Codex.tool_kind("mcp__linear__create_issue")
    assert_nil Sessions::Adapters::ClaudeCode.tool_kind("SomeUnknownTool")
  end
end
