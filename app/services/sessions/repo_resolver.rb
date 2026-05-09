require "open3"

module Sessions
  class RepoResolver
    def self.call(project_path, path_lookup: nil)
      new(project_path, path_lookup: path_lookup).call
    end

    def initialize(project_path, path_lookup: nil)
      @project_path = project_path
      @path_lookup = path_lookup
    end

    def call
      return nil unless @project_path.present?

      lookup = @path_lookup || PathLookup.build
      base_path = @project_path.sub(/--claude-worktrees-.*$/, "")
      fs_path = lookup[base_path]

      if fs_path && fs_path.include?("/.claude/worktrees/")
        fs_path = fs_path.sub(%r{/\.claude/worktrees/.*$}, "")
      end

      return nil unless fs_path && Dir.exist?(fs_path)
      return nil unless git_repo?(fs_path)

      remote_url = git_remote_url(fs_path)

      if remote_url
        owner_repo = parse_owner_repo(remote_url)
        return nil unless owner_repo

        Repo.find_or_create_by!(name: owner_repo) do |r|
          r.remote_url = remote_url
          r.filesystem_path = fs_path
        end
      else
        dir_name = File.basename(fs_path)
        Repo.find_or_create_by!(name: "local/#{dir_name}") do |r|
          r.filesystem_path = fs_path
        end
      end
    rescue => e
      Rails.logger.warn("Could not resolve repo for #{@project_path}: #{e.message}")
      nil
    end

    private

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
      return output.strip.presence if status.success?
      nil
    rescue
      nil
    end

    def parse_owner_repo(remote_url)
      if remote_url =~ %r{[:/]([^/]+)/([^/]+?)(?:\.git)?$}
        "#{$1}/#{$2}"
      end
    end
  end
end
