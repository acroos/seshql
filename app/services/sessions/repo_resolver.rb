require "open3"

module Sessions
  # Maps a session's working directory to a `repos` row by asking git what
  # remote lives there. Directories that are not repositories, or that no
  # longer exist, resolve to nil rather than raising.
  class RepoResolver
    # A worktree checkout belongs to the repository it was cut from, not to a
    # repo of its own, so the worktree segment is trimmed first.
    WORKTREE_PATHS = [ %r{/\.claude/worktrees/.*\z}, %r{/\.codex/worktrees/.*\z} ].freeze

    def self.call(directory) = new(directory).call

    def initialize(directory)
      @directory = directory
    end

    def call
      path = base_directory
      return nil unless path && Dir.exist?(path) && git_repo?(path)

      remote_url = git_remote_url(path)
      remote_url ? repo_from_remote(remote_url, path) : repo_from_directory(path)
    rescue => e
      Rails.logger.warn("Could not resolve repo for #{@directory}: #{e.message}")
      nil
    end

    private

    def base_directory
      return nil if @directory.blank?

      WORKTREE_PATHS.reduce(@directory) { |path, pattern| path.sub(pattern, "") }
    end

    def repo_from_remote(remote_url, path)
      owner_repo = parse_owner_repo(remote_url)
      return nil unless owner_repo

      Repo.find_or_create_by!(name: owner_repo) do |repo|
        repo.remote_url = remote_url
        repo.filesystem_path = path
      end
    end

    def repo_from_directory(path)
      Repo.find_or_create_by!(name: "local/#{File.basename(path)}") do |repo|
        repo.filesystem_path = path
      end
    end

    def git_repo?(path)
      _, status = Open3.capture2("git", "-C", path, "rev-parse", "--git-dir")
      status.success?
    rescue
      false
    end

    def git_remote_url(path)
      output, status = Open3.capture2("git", "-C", path, "remote", "get-url", "origin")
      return output.strip.presence if status.success?

      remotes, status = Open3.capture2("git", "-C", path, "remote")
      return nil unless status.success?

      first_remote = remotes.strip.lines.first&.strip
      return nil unless first_remote

      output, status = Open3.capture2("git", "-C", path, "remote", "get-url", first_remote)
      status.success? ? output.strip.presence : nil
    rescue
      nil
    end

    def parse_owner_repo(remote_url)
      "#{$1}/#{$2}" if remote_url =~ %r{[:/]([^/]+)/([^/]+?)(?:\.git)?\z}
    end
  end
end
