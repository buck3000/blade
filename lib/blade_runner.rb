require "eventmachine"
require "pathname"
require "ostruct"

require "blade_runner/version"
require "blade_runner/concerns/knife"
require "blade_runner/server"
require "blade_runner/file_watcher"
require "blade_runner/console"
require "blade_runner/ci"
require "blade_runner/test_results"
require "blade_runner/browser"

browsers = Dir[File.dirname(__FILE__) + "/blade_runner/browsers/*.rb"].map { |f| File.basename(f) }
browsers.each do |filename|
  require "blade_runner/browsers/#{filename}"
end

module BladeRunner
  extend self

  attr_reader :config, :browsers

  def start(options = {})
    %w( INT ).each do |signal|
      trap(signal) { stop }
    end

    at_exit do
      stop
      exit $!.status if $!.is_a?(SystemExit)
    end

    @config = OpenStruct.new(options)

    config.port ||= 9876
    config.mode ||= :console
    config.asset_paths = Array(config.asset_paths)
    config.test_scripts = Array(config.test_scripts)
    config.watch_files = Array(config.watch_files)

    plugins = config.plugins || {}
    config.plugins = OpenStruct.new
    plugins.each do |name, plugin_config|
      config.plugins[name] = OpenStruct.new(plugin_config)
      require "blade_runner/#{name}"
    end

    clean

    EM.run do
      get_supported_browsers do |browsers|
        @browsers = browsers
        @runnables = [server, browsers].flatten

        EM::Iterator.new(@runnables).each do |child, iterator|
          operation = -> { child.start }
          callback = ->(result) { iterator.next }
          EM.defer(operation, callback)
        end

        runner = runner_for_mode
        @runnables << runner
        runner.start
      end
    end
  end

  def stop
    return if @stopping
    @stopping = true
    @runnables.each { |c| c.stop rescue nil }
    EM.stop_event_loop
  rescue
    nil
  end

  def lib_path
    Pathname.new(File.dirname(__FILE__))
  end

  def root_path
    lib_path.join("../")
  end

  def tmp_path
    root_path.join("tmp")
  end

  def server
    @server ||= Server.new
  end

  def client
    @client ||= Faye::Client.new("http://localhost:#{config.port}/faye")
  end

  def file_watcher
    @file_watcher ||= FileWatcher.new
  end

  def console
    @console ||= Console.new
  end

  def ci
    @ci ||= CI.new
  end

  private
    ALLOWED_MODES = [:ci, :console]

    def get_supported_browsers
      operation = -> { Browser.subclasses.map(&:new).select(&:supported?) }
      callback = ->(result) { yield(result) }
      EM.defer(operation, callback)
    end

    def runner_for_mode
      if ALLOWED_MODES.include?(config.mode)
        send(config.mode)
      end
    end

    def clean
      FileUtils.rm_rf(tmp_path)
      FileUtils.mkdir_p(tmp_path)
    end
end
