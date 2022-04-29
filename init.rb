require 'redmine'
File.dirname(__FILE__) +  "/lib/redmine_git_remote/repositories_helper_patch"

Redmine::Scm::Base.add "GitRemote"
Redmine::Scm::Base.add "GitLab"

Redmine::Plugin.register :redmine_git_remote do
  name 'Redmine Git Remote'
  author 'Marius Wagner'
  url 'https://github.com/heldbrendel/redmine_git_remote.git'
  description 'Automatically clone and fetch remote git repositories'
  version '0.1.0'

  settings :default => {
    'git_remote_repo_clone_path' => Pathname.new(__FILE__).join("../").realpath.to_s + "/repos",
  }, :partial => 'settings/git_remote_settings'
end
