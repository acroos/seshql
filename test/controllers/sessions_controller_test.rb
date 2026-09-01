require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    with_agent_homes do |homes|
      claude_history(homes[:claude_home], [ TranscriptFixtures::PROJECT_DIR ])
      Sessions::Ingester.call(write_claude_transcript(homes[:claude_home], claude_lines))
      Sessions::Ingester.call(write_codex_transcript(homes[:codex_home], codex_lines))
    end
  end

  test "the index lists sessions from both agents" do
    get sessions_path

    assert_response :success
    assert_select "body", text: /Claude Code/
    assert_select "body", text: /Codex/
  end

  test "the index filters by agent" do
    get sessions_path(source: "codex")

    assert_response :success
    assert_select "a[href=?]", session_path(TranscriptFixtures::CODEX_THREAD_ID)
    assert_select "a[href=?]", session_path(TranscriptFixtures::CLAUDE_SESSION_ID), count: 0
  end

  test "the index filters by working directory" do
    get sessions_path(project: TranscriptFixtures::PROJECT_DIR)

    assert_response :success
    # Both agents ran in the same directory, so both survive the filter.
    assert_select "a[href=?]", session_path(TranscriptFixtures::CODEX_THREAD_ID)
    assert_select "a[href=?]", session_path(TranscriptFixtures::CLAUDE_SESSION_ID)
  end

  test "renders the detail page for each agent" do
    [ TranscriptFixtures::CLAUDE_SESSION_ID, TranscriptFixtures::CODEX_THREAD_ID ].each do |id|
      get session_path(id)

      assert_response :success
      assert_select "body", text: /check the repo state/
    end
  end

  test "injected context renders collapsed, not as something you said" do
    with_agent_homes do |homes|
      Sessions::Ingester.call(install_real_codex_rollout(homes[:codex_home]))
    end

    get session_path(TranscriptFixtures::REAL_CODEX_THREAD_ID)

    assert_response :success
    # The four injected blocks collapse (the view uses `details` for tool
    # calls too, so match on the label); only the typed prompt gets "You".
    assert_select "details summary", text: /Injected context/, count: 4
    assert_select "span", text: "You", count: 1
    assert_select "body", text: /I want you to create a new directory/
  end

  test "the Codex detail page shows its own cost categories" do
    get session_path(TranscriptFixtures::CODEX_THREAD_ID)

    assert_response :success
    # OpenAI has no split cache-write tiers, so those Anthropic-only lines
    # must not appear.
    assert_select "body", text: /Cache write/
    assert_select "body", { text: /Cache write \(1h\)/, count: 0 }
  end
end
