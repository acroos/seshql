module ApplicationHelper
  def format_tokens(count)
    if count >= 1_000_000
      "#{(count / 1_000_000.0).round(1)}M"
    elsif count >= 1_000
      "#{(count / 1_000.0).round(1)}K"
    else
      count.to_s
    end
  end

  def format_usd(amount)
    return "—" if amount.nil?
    amount = amount.to_f
    return "$0" if amount.zero?
    return "<$0.01" if amount < 0.01
    return "$#{format('%.2f', amount)}" if amount < 1_000
    "$#{number_with_delimiter(amount.round)}"
  end

  def format_duration(ms)
    return "—" unless ms && ms > 0
    total_seconds = ms / 1000
    if total_seconds >= 86_400
      days = total_seconds / 86_400
      hours = (total_seconds % 86_400) / 3600
      "#{days}d #{hours}h"
    elsif total_seconds >= 3600
      hours = total_seconds / 3600
      mins = (total_seconds % 3600) / 60
      "#{hours}h #{mins}m"
    elsif total_seconds >= 60
      mins = total_seconds / 60
      secs = total_seconds % 60
      "#{mins}m #{secs}s"
    else
      "#{total_seconds}s"
    end
  end

  # Hover text spelling out how a session's tokens split across priced
  # categories — the totals are dominated by cheap cache reads, so the mix
  # matters more than the headline number.
  def token_mix_title(session)
    [
      "Fresh input #{format_tokens(session.fresh_input_tokens)}",
      "Cache write #{format_tokens(session.total_cache_creation_tokens)}",
      "Cache read #{format_tokens(session.total_cache_read_tokens)}",
      "Output #{format_tokens(session.total_output_tokens)}"
    ].join(" · ")
  end

  PR_ICON_PATH = "M7.177 3.073L9.573.677A.25.25 0 0110 .854v4.792a.25.25 0 01-.427.177L7.177 3.427a.25.25 0 010-.354zM3.75 2.5a.75.75 0 100 1.5.75.75 0 000-1.5zm-2.25.75a2.25 2.25 0 113 2.122v5.256a2.251 2.251 0 11-1.5 0V5.372A2.25 2.25 0 011.5 3.25zM11 2.5h-1V4h1a1 1 0 011 1v5.628a2.251 2.251 0 101.5 0V5A2.5 2.5 0 0011 2.5zm1 10.25a.75.75 0 111.5 0 .75.75 0 01-1.5 0zM3.75 12a.75.75 0 100 1.5.75.75 0 000-1.5z".freeze

  def pr_icon(css_class)
    tag.svg(tag.path(d: PR_ICON_PATH), class: css_class, fill: "currentColor", viewBox: "0 0 16 16")
  end

  def format_project(path)
    return "unknown" unless path
    path.gsub(/^-/, "").gsub("-", "/")
  end

  def short_project(path)
    full = format_project(path)
    parts = full.split("/")
    parts.last(2).join("/")
  end

  def time_ago_short(time)
    return "—" unless time
    seconds = (Time.current - time).to_i
    case seconds
    when 0..59 then "#{seconds}s ago"
    when 60..3599 then "#{seconds / 60}m ago"
    when 3600..86399 then "#{seconds / 3600}h ago"
    when 86400..604799 then "#{seconds / 86400}d ago"
    else time.strftime("%b %-d")
    end
  end
end
