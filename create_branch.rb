require "octokit"
require "open3"
require "pathname"
require "tmpdir"

MAX_ATTEMPTS = 5

class GitError < StandardError; end

def gh_token
  gh_token_from_env = ENV['BOT_TOKEN'].to_s.strip
  gh_token_from_env = ENV['GH_ACCESS_TOKEN'].to_s.strip if gh_token_from_env.empty?
  raise "!! ERROR: Invalid GitHub Token" if gh_token_from_env.empty?
  gh_token_from_env
end

def github_client
  @github_client ||= Octokit::Client.new(access_token: gh_token, auto_paginate: true)
end

# Retry network operations that fail with transient errors
def with_retries(description)
  attempt = 0
  begin
    attempt += 1
    yield
  rescue GitError, Octokit::ServerError, Faraday::ConnectionFailed, Faraday::TimeoutError => e
    raise if attempt >= MAX_ATTEMPTS
    wait = 2 ** attempt
    puts "!! #{description} failed (#{e.class}). Retrying in #{wait}s (attempt #{attempt}/#{MAX_ATTEMPTS})"
    sleep wait
    retry
  end
end

# Run a git command in dir, authenticating with the GitHub token when auth is true.
# The auth header is passed through the environment, scoped to github.com, so the
# token doesn't appear in the process list.
# Lazy fetching is disabled so a command that needs the papers' blobs fails
# instead of silently downloading the whole repository.
def git(*args, dir:, env: {}, auth: false)
  git_env = { "GIT_NO_LAZY_FETCH" => "1" }
  if auth
    git_env.merge!("GIT_CONFIG_COUNT" => "1",
                   "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraheader",
                   "GIT_CONFIG_VALUE_0" => "AUTHORIZATION: basic #{["x-access-token:#{gh_token}"].pack("m0")}")
  end
  output, status = Open3.capture2e(git_env.merge(env), "git", *args, chdir: dir)
  raise GitError, "!! ERROR: git #{args.first} failed:\n#{output.gsub(gh_token, "***")}" unless status.success?
  output.strip
end

# Only upload regular files that are really inside folder. Following a symlink
# could publish files from the runner, e.g. ones containing secrets.
def uploadable?(file_path, folder)
  if File.symlink?(file_path) || !File.file?(file_path)
    puts "!! Skipping #{file_path}: not a regular file"
    return false
  end
  unless File.realpath(file_path).start_with?(File.realpath(folder) + File::SEPARATOR)
    puts "!! Skipping #{file_path}: outside #{folder}"
    return false
  end
  true
end

def get_main_branch(repo_dir)
  heads = with_retries("Listing branches") { git("ls-remote", "--heads", "origin", "main", "master", dir: repo_dir, auth: true) }
  heads.include?("refs/heads/main") ? "main" : "master"
end

# Commits are attributed to the owner of the token, as they were when using the Contents API
def committer_env
  user = github_client.user
  name = user.name.to_s.empty? ? user.login : user.name
  email = "#{user.id}+#{user.login}@users.noreply.github.com"
  { "GIT_AUTHOR_NAME" => name, "GIT_AUTHOR_EMAIL" => email, "GIT_COMMITTER_NAME" => name, "GIT_COMMITTER_EMAIL" => email }
rescue Octokit::Error
  name = "Open Journals uploader"
  email = "noreply@github.com"
  { "GIT_AUTHOR_NAME" => name, "GIT_AUTHOR_EMAIL" => email, "GIT_COMMITTER_NAME" => name, "GIT_COMMITTER_EMAIL" => email }
end

issue_id = ENV["ISSUE_ID"]
pdf_path = ENV["PDF_PATH"].to_s.strip
jats_path = ENV["JATS_PATH"].to_s.strip
crossref_path = ENV["CROSSREF_PATH"].to_s.strip
papers_repo = ENV["PAPERS_REPO"]
branch_prefix = ENV["BRANCH_PREFIX"]

id = "%05d" % issue_id
branch = branch_prefix.empty? ? id.to_s : "#{branch_prefix}.#{id}"

pdf_uploaded_path = "#{branch}/10.21105.#{branch}.pdf"
jats_uploaded_path = "#{branch}/paper.jats/10.21105.#{branch}.jats"
crossref_uploaded_path = "#{branch}/10.21105.#{branch}.crossref.xml"

# Map of local file => path in the papers repo
files_to_upload = {}
if !pdf_path.empty? && File.exist?(pdf_path) && uploadable?(pdf_path, File.dirname(pdf_path))
  files_to_upload[File.expand_path(pdf_path)] = pdf_uploaded_path
end
if !crossref_path.empty? && File.exist?(crossref_path) && uploadable?(crossref_path, File.dirname(crossref_path))
  files_to_upload[File.expand_path(crossref_path)] = crossref_uploaded_path
end

# Add all files in the JATS' directory if present
if !jats_path.empty? && File.exist?(jats_path)
  jats_files_folder = File.dirname(jats_path)
  Dir[File.join(jats_files_folder, "**/*.*")].each do |jats_file|
    next unless uploadable?(jats_file, jats_files_folder)
    jats_file_name = Pathname(jats_file).relative_path_from(jats_files_folder).to_s
    uploaded_path = jats_file_name == "paper.jats" ? jats_uploaded_path : "#{branch}/paper.jats/#{jats_file_name}"
    files_to_upload[File.expand_path(jats_file)] = uploaded_path
  end
end

# Build a single commit on top of the main branch and push it with git.
# The GitHub API times out creating trees in large papers repos, so we use a
# shallow, blobless fetch (trees only) and write the new tree locally.
Dir.mktmpdir do |repo_dir|
  git("init", "-q", dir: repo_dir)
  git("remote", "add", "origin", "https://github.com/#{papers_repo}.git", dir: repo_dir)

  main_branch = get_main_branch(repo_dir)
  with_retries("Fetching #{main_branch}") { git("fetch", "-q", "--depth=1", "--filter=blob:none", "origin", main_branch, dir: repo_dir, auth: true) }
  main_sha = git("rev-parse", "FETCH_HEAD", dir: repo_dir)

  index_env = { "GIT_INDEX_FILE" => File.join(repo_dir, "paper-index") }
  git("read-tree", main_sha, dir: repo_dir, env: index_env)
  files_to_upload.each do |local_path, uploaded_path|
    blob_sha = git("hash-object", "-w", local_path, dir: repo_dir)
    git("update-index", "--add", "--cacheinfo", "100644,#{blob_sha},#{uploaded_path}", dir: repo_dir, env: index_env)
  end
  # --missing-ok: the existing papers' blobs were not fetched and are not needed
  tree_sha = git("write-tree", "--missing-ok", dir: repo_dir, env: index_env)
  commit_sha = git("commit-tree", tree_sha, "-p", main_sha, "-m", "Creating 10.21105.#{branch} files", dir: repo_dir, env: committer_env)

  # Force push replaces any previous version of the paper branch in one step
  with_retries("Pushing #{branch}") { git("push", "-q", "--force", "origin", "#{commit_sha}:refs/heads/#{branch}", dir: repo_dir, auth: true) }
end

html_url = ->(path) { "https://github.com/#{papers_repo}/blob/#{branch}/#{path}" }
download_url = ->(path) { "https://raw.githubusercontent.com/#{papers_repo}/#{branch}/#{path}" }

if files_to_upload.value?(pdf_uploaded_path)
  system("echo 'pdf_html_url=#{html_url.(pdf_uploaded_path)}' >> $GITHUB_OUTPUT")
  system("echo 'pdf_download_url=#{download_url.(pdf_uploaded_path)}' >> $GITHUB_OUTPUT")
end

if files_to_upload.value?(crossref_uploaded_path)
  system("echo 'crossref_html_url=#{html_url.(crossref_uploaded_path)}' >> $GITHUB_OUTPUT")
  system("echo 'crossref_download_url=#{download_url.(crossref_uploaded_path)}' >> $GITHUB_OUTPUT")
end

if files_to_upload.value?(jats_uploaded_path)
  system("echo 'jats_html_url=#{html_url.(jats_uploaded_path)}' >> $GITHUB_OUTPUT")
  system("echo 'jats_download_url=#{download_url.(jats_uploaded_path)}' >> $GITHUB_OUTPUT")
end
