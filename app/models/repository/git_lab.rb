require 'redmine/scm/adapters/git_adapter'
require 'pathname'
require 'fileutils'
# require 'open3'
require_dependency 'redmine_git_remote/poor_mans_capture3'

class Repository::GitLab < Repository::Git

  before_validation :initialize_clone

  safe_attributes 'extra_info', :if => lambda { |repository, _user| repository.new_record? }

  # TODO: figure out how to do this safely (if at all)
  # before_deletion :rm_removed_repo
  # def rm_removed_repo
  #   if Repository.find_all_by_url(repo.url).length <= 1
  #     system "rm -Rf #{self.clone_path}"
  #   end
  # end

  def extra_clone_url
    return nil unless extra_info
    extra_info["extra_clone_url"]
  end

  def extra_clone_token
    return nil unless extra_info
    extra_info["extra_clone_token"]
  end

  def clone_url
    self.extra_clone_url
  end

  def clone_token
    self.extra_clone_token
  end

  def clone_path
    self.url
  end

  def clone_host
    p = parse(clone_url)
    return p[:host]
  end

  def clone_protocol_http?
    # Possible valid values (via http://git-scm.com/book/ch4-1.html):
    #  ssh://user@server/project.git
    #  user@server:project.git
    #  server:project.git
    # For simplicity we just assume if it's not HTTP(S), then it's SSH.
    clone_url.match(/^http/)
  end

  # Hook into Repository.fetch_changesets to also run 'git fetch'.
  def fetch_changesets
    # ensure we don't fetch twice during the same request
    return if @already_fetched
    @already_fetched = true

    puts "Calling fetch changesets on #{clone_path}"
    # runs git fetch
    self.fetch
    super
  end

  # Override default_branch to fetch, otherwise caching problems in
  # find_project_repository prevent Repository::Git#fetch_changesets from running.
  #
  # Ideally this would only be run for RepositoriesController#show.
  def default_branch
    if self.branches == [] && self.project.active? && Setting.autofetch_changesets?
      # git_adapter#branches caches @branches incorrectly, reset it
      scm.instance_variable_set :@branches, nil
      # NB: fetch_changesets is idemptotent during a given request, so OK to call it 2x
      self.fetch_changesets
    end
    super
  end

  # called in before_validate handler, sets form errors
  def initialize_clone
    # avoids crash in RepositoriesController#destroy
    return unless attributes["extra_info"]["extra_clone_url"]

    p = parse(attributes["extra_info"]["extra_clone_url"])
    self.identifier = p[:identifier] if identifier.empty?

    base_path = Setting.plugin_redmine_git_remote['git_remote_repo_clone_path']
    base_path = base_path + "/" unless base_path.end_with?("/")

    self.url = base_path + p[:path] if url.empty?

    err = ensure_possibly_empty_clone_exists
    errors.add :extra_clone_url, err if err
  end

  # equality check ignoring trailing whitespace and slashes
  def two_remotes_equal(a, b)
    a.chomp.gsub(/\/$/, '') == b.chomp.gsub(/\/$/, '')
  end

  def ensure_possibly_empty_clone_exists

    if clone_protocol_http?
      extra_header_param = "http.extraHeader=\"Authorization: Basic #{Base64.strict_encode64(":" + extra_clone_token)}\""
      cmd = "git -c #{extra_header_param} ls-remote -h #{clone_url}"
      unless system(cmd)
        return "#{clone_url} is not a valid remote."
      end
    else
      unless system "git", "ls-remote", "-h", clone_url
        return "#{clone_url} is not a valid remote."
      end
    end

    puts "Clone path #{clone_path}"

    if Dir.exists?(clone_path)
      if clone_protocol_http?
        extra_header_param = "http.extraHeader=\"Authorization: Basic #{Base64.strict_encode64(":" + extra_clone_token)}\""
        cmd = "git -c #{extra_header_param} --git-dir #{clone_path} config --get remote.origin.url"
        existing_repo_remote = `#{cmd}`; status = $?
        extra_header_param = "http.extraHeader=\"Authorization: Basic #{Base64.strict_encode64(":" + extra_clone_token)}\""
        cmd = "git -c #{extra_header_param} --git-dir #{clone_path} config --get remote.origin.url"
        existing_repo_remote = `#{cmd}`; status = $?
      else
        existing_repo_remote, status = RedmineGitRemote::PoorMansCapture3::capture2(
          "git", "--git-dir", clone_path, "config", "--get", "remote.origin.url")
      end
      return "Unable to run: git --git-dir #{clone_path} config --get remote.origin.url" unless status.success?

      unless two_remotes_equal(existing_repo_remote, clone_url)
        return "Directory '#{clone_path}' already exits, none matching clone url: #{existing_repo_remote}"
      end

    else
      unless system("git init --bare #{clone_path}")
        return "Unable to run: git init --bare #{clone_path}"
      end

      extra_header_param = "http.extraHeader=\"Authorization: Basic #{Base64.strict_encode64(":" + extra_clone_token)}\""
      cmd = "git -c #{extra_header_param} --git-dir #{clone_path} remote add --mirror=fetch origin #{clone_url}"
      unless system(cmd)
        return "Unable to run: git --git-dir #{clone_path} remote add --mirror=fetch origin #{clone_url}"
      end
    end
  end

  unloadable

  def self.scm_name
    'GitLab HTTP'
  end

  # TODO: first validate git URL and display error message
  def parse(url)
    url.strip!

    ret = {}
    # start with http://github.com/evolvingweb/git_remote or git@git.ewdev.ca:some/repo.git
    ret[:url] = url

    # NB: Starting lines with ".gsub" is a syntax error in ruby 1.8.
    #     See http://stackoverflow.com/q/12906048/9621
    # path is github.com/evolvingweb/muhc-ci
    ret[:path] = url.gsub(/^.*:\/\//, '').# Remove anything before ://
    gsub(/:/, '/').# convert ":" to "/"
    gsub(/^.*@/, '').# Remove anything before @
    gsub(/\.git$/, '') # Remove trailing .git
    ret[:host] = ret[:path].split('/').first
    #TODO: handle project uniqueness automatically or prompt
    ret[:identifier] = ret[:path].split('/').last.downcase.gsub(/[^a-z0-9_-]/, '-')
    return ret
  end

  def fetch
    puts "Fetching repo #{clone_path}"

    err = ensure_possibly_empty_clone_exists
    Rails.logger.warn err if err

    # If dir exists and non-empty, should be safe to 'git fetch'
    if clone_protocol_http?
      extra_header_param = "http.extraHeader=\"Authorization: Basic #{Base64.strict_encode64(":" + extra_clone_token)}\""
      cmd = "git -c #{extra_header_param} --git-dir #{clone_path} fetch --all"
      unless system(cmd)
        Rails.logger.warn "Unable to run 'git -c #{clone_path} fetch --all'"
      end
    else
      unless system "git", "--git-dir", clone_path, "fetch", "--all"
        Rails.logger.warn "Unable to run 'git -c #{clone_path} fetch --all'"
      end
    end
  end
end