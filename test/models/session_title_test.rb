require "test_helper"

# The `prompt_title` / `prompt_title_rank` / `title_snippet` trio in
# `db/functions`, exercised directly. Between them they decide what every
# session on `/sessions` is called.
class SessionTitleTest < ActiveSupport::TestCase
  test "a slash command with no arguments names itself, not its XML" do
    assert_equal "/clear", prompt_title(<<~PROMPT)
      <command-name>/clear</command-name>
                  <command-message>clear</command-message>
                  <command-args></command-args>
    PROMPT
  end

  test "a slash command with arguments keeps both halves" do
    # This one leads with `<command-message>`; `/clear` leads with
    # `<command-name>`. Neither order may change the result.
    assert_equal "/ui-ux-pro-max — redesign the leaderboard", prompt_title(<<~PROMPT)
      <command-message>ui-ux-pro-max</command-message>
      <command-name>/ui-ux-pro-max</command-name>
      <command-args>redesign the leaderboard</command-args>
    PROMPT
  end

  test "a bang shell command reads as a shell command" do
    assert_equal "$ git merge --ff-only main",
                 prompt_title("<bash-input>git merge --ff-only main</bash-input>")
  end

  test "harness output is not a name at all" do
    [
      "<bash-stdout>On branch main</bash-stdout>",
      "<local-command-stdout>done</local-command-stdout>",
      "<local-command-caveat>Caveat: the messages below…</local-command-caveat>",
      "<task-notification>agent finished</task-notification>",
      ""
    ].each do |prompt|
      assert_nil prompt_title(prompt), "expected no title for #{prompt.inspect}"
      assert_equal 99, prompt_title_rank(prompt)
    end
  end

  test "prose is collapsed onto one line and left otherwise intact" do
    assert_equal "Fix the ingester. It drops rows.",
                 prompt_title("Fix the ingester.\n\n   It drops rows.  ")
  end

  test "a system reminder appended to a prompt is dropped" do
    assert_equal "ship it",
                 prompt_title("ship it<system-reminder>Do not mention this.</system-reminder>")
  end

  test "prose that merely quotes a command tag stays prose" do
    quoted = %(the title reads "<command-name>/clear</command-name>" which is wrong)
    assert_equal quoted, prompt_title(quoted)
  end

  test "ranking puts a stated request ahead of mode commands and shell" do
    ranked = [
      "<command-name>/model</command-name>",
      "<bash-input>git status</bash-input>",
      "ok",
      "Make the ingester agent-agnostic",
      "<command-name>/fix</command-name><command-args>the failing test</command-args>"
    ].sort_by { |prompt| prompt_title_rank(prompt) }.map { |prompt| prompt_title(prompt) }

    assert_equal [ "/fix — the failing test", "Make the ingester agent-agnostic" ],
                 ranked.first(2).sort
    assert_equal [ "ok", "$ git status", "/model" ], ranked.last(3)
  end

  test "truncation falls back to a word boundary" do
    assert_equal "one two…", title_snippet("one two three", 9)
    # Nothing to trim back to, so the word is cut and the budget still holds.
    assert_equal "aaaaa…", title_snippet("aaaaaaaaaa", 5)
    assert_equal "short enough", title_snippet("short enough", 90)
    assert_nil title_snippet(nil, 90)
  end

  private

  def prompt_title(prompt) = scalar("SELECT prompt_title(?)", prompt)

  def prompt_title_rank(prompt) = scalar("SELECT prompt_title_rank(?)", prompt)

  def title_snippet(body, max) = scalar("SELECT title_snippet(?, ?)", body, max)

  def scalar(sql, *binds)
    Session.connection.select_value(ActiveRecord::Base.sanitize_sql_array([ sql, *binds ]))
  end
end
