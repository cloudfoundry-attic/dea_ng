desc "Install/run log server for tests"
namespace :log_server do
  ROOT = File.expand_path("../../..", __FILE__)
  LOG_SERVER_BRANCH = "master"
  LOG_SERVER_REPO = "https://github.com/cloudfoundry/logplex.git"

  desc "Run log server for integration tests"
  task :run => [:install] do
    Dir.chdir(log_server_dir) do
      system <<-RUN_SERVER
LOGPLEX_AUTH_KEY=auth_key LOGPLEX_COOKIE=123 INSTANCE_NAME=logplex1 LOCAL_IP=`hostname` \
LOGPLEX_CONFIG_REDIS_URL=redis://127.0.0.1:6379 \
LOGPLEX_STATS_REDIS_URL=redis://127.0.0.1 \
REDIS_URL=redis://127.0.0.1 \
bin/logplex
RUN_SERVER
    end
  end

  desc "Install log server for integration tests"
  task :install do
    fetch_log_server
    build_log_server
  end

  def fetch_log_server
    unless Dir.exists?(log_server_dir)
      system "git clone #{LOG_SERVER_REPO} #{log_server_dir} --depth 1"
    end

    Dir.chdir(log_server_dir) do
      system "git pull origin #{LOG_SERVER_BRANCH}"
    end
  end

  def build_log_server
    Dir.chdir(log_server_dir) do
      system "./rebar --config public.rebar.config get-deps compile"
    end
  end

  def log_server_dir
    "#{ROOT}/tmp/log-server"
  end
end
