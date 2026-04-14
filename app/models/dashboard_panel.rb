class DashboardPanel < ApplicationRecord
  belongs_to :dashboard

  validates :title, :sql_query, :chart_type, presence: true
  validates :chart_type, inclusion: { in: %w[bar line stacked_bar] }
  validates :value_column, presence: true, if: -> { series_column.present? }

  STATEMENT_TIMEOUT_MS = 10_000
  MAX_ROWS = 500

  FORBIDDEN_PATTERNS = [
    /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE|COPY)\b/i,
    /\b(INTO\s+OUTFILE|LOAD\s+DATA|EXEC|EXECUTE)\b/i,
    /;\s*\S/,
  ].freeze

  def execute_query
    error = validate_sql
    return { error: error } if error

    query = ensure_limit(sql_query)
    results = ActiveRecord::Base.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '#{STATEMENT_TIMEOUT_MS}'")
      ActiveRecord::Base.connection.exec_query(query)
    end

    { results: results, chart_data: build_chart_data(results) }
  rescue ActiveRecord::StatementInvalid, PG::Error => e
    { error: e.message.sub(/^PG::.*ERROR:\s*/, "") }
  end

  def build_chart_data(results)
    return nil if results.rows.empty?

    if series_column.present? && value_column.present?
      build_pivoted_chart_data(results)
    else
      build_wide_chart_data(results)
    end
  end

  private

  # Long format: x_column, series_column, value_column
  # Pivots rows into { labels: [...], datasets: [{ label, data }] }
  def build_pivoted_chart_data(results)
    x_idx = results.columns.index(x_column)
    series_idx = results.columns.index(series_column)
    value_idx = results.columns.index(value_column)

    return nil unless x_idx && series_idx && value_idx

    labels = results.rows.map { |r| r[x_idx] }.uniq
    series_names = results.rows.map { |r| r[series_idx] }.uniq

    lookup = {}
    results.rows.each do |row|
      lookup[[row[x_idx], row[series_idx]]] = row[value_idx].to_f
    end

    datasets = series_names.map do |name|
      {
        label: name.to_s,
        data: labels.map { |l| lookup[[l, name]] || 0 }
      }
    end

    { labels: labels.map(&:to_s), datasets: datasets }
  end

  # Wide format: first column = labels, remaining numeric columns = series
  def build_wide_chart_data(results)
    label_col = x_column.present? ? results.columns.index(x_column) : 0
    label_col ||= 0

    labels = results.rows.map { |r| r[label_col].to_s }

    datasets = results.columns.each_with_index.filter_map do |col, i|
      next if i == label_col

      values = results.rows.map { |r| r[i].to_f }
      { label: col, data: values }
    end

    { labels: labels, datasets: datasets }
  end

  def validate_sql
    normalized = sql_query.gsub(/--.*$/, "").gsub(/\/\*.*?\*\//m, "").strip
    return "Query cannot be empty." if normalized.blank?

    unless normalized.match?(/\A\s*(SELECT|WITH)\b/i)
      return "Only SELECT queries are allowed."
    end

    FORBIDDEN_PATTERNS.each do |pattern|
      return "Query contains a forbidden statement." if normalized.match?(pattern)
    end

    nil
  end

  def ensure_limit(sql)
    if sql.match?(/\bLIMIT\s+\d+/i)
      sql.gsub(/\bLIMIT\s+(\d+)/i) { "LIMIT #{[Regexp.last_match(1).to_i, MAX_ROWS].min}" }
    else
      "#{sql.chomp(';').strip}\nLIMIT #{MAX_ROWS}"
    end
  end
end
