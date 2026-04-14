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

  def format_duration(ms)
    return "—" unless ms && ms > 0
    total_seconds = ms / 1000
    if total_seconds >= 3600
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
