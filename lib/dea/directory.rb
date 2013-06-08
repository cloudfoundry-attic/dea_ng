# coding: UTF-8

# Copyright (c) 2009-2012 VMware, Inc.
require "pathname"

require "steno"
require "steno/core_ext"

# Rack::Directory serves entries below the +root+ given, according to the
# path info of the Rack request. If a directory is found, the file's contents
# will be presented in an html based index. If a file is found, the env will
# be passed to the specified +app+.
#
# If +app+ is not specified, a Rack::File of the same +root+ will be used.

module Dea
  class FileServer < Rack::File
    # based on Rack::File, just add the NOFOLLOW flag
    def each
      F.open(@path, File::RDONLY | File::NOFOLLOW | File::BINARY) do |file|
        file.seek(@range.begin)
        remaining_len = @range.end-@range.begin+1
        while remaining_len > 0
          part = file.read([8192, remaining_len].min)
          break unless part
          remaining_len -= part.length

          yield part
        end
      end
    end
  end

  class Directory
    attr_reader :files
    attr_accessor :root, :path

    def initialize(instance_registry)
      @instance_registry = instance_registry
    end

    def call(env)
      dup._call(env)
    end

    F = ::File

    def _call(env)
      @env = env.dup
      @script_name = env['SCRIPT_NAME']

      path_info = Rack::Utils.unescape(env['PATH_INFO'])
      path_parts = path_info.split("/")

      logger.debug2("directory-server.request.handle", :path => path_info)

      # Lookup container associated with request
      instance_id = path_parts[1]
      instance = @instance_registry.lookup_instance(instance_id)

      if instance.nil?
        logger.warn "directory-server.instance.unknown", :instance_id => instance_id
        return entity_not_found
      end

      if !instance.instance_path_available?
        logger.warn "directory-server.path.unavailable",
          :instance_id => instance_id
        return entity_not_found
      end

      # The instance path is the root for all future operations
      @root = Pathname.new(instance.instance_path).realpath
      @app = FileServer.new(@root)

      # Strip the instance id from the path. This is required to keep backwards
      # compatibility with how file URLs are constructed with DeaV1.
      @path_info = path_parts[2, path_parts.size - 1].join("/")
      @env["PATH_INFO"] = @path_info
      @path = F.expand_path(F.join(@root, @path_info))

      if not File.exists? @path
        return entity_not_found
      end

      resolve_symlink
      if forbidden = check_forbidden
        logger.warn "directory-server.path.forbidden", :path => @path
        forbidden
      else
        list_path
      end
    rescue => e
      logger.error "directory-server.exception", :exception => e,
        :backtrace => e.backtrace

      raise e
    end

    def resolve_symlink
      real_path = Pathname.new(@path).realpath.to_s
      return if real_path == @path

      # Adjust env only if user has access rights to real path
      app_base =  File.join(@root, @path_info.sub(/^\/+/,'').split('/').first)
      if real_path.start_with?(app_base)
        m = real_path.match(@root.to_s)
        return if m.nil?
        @env['PATH_INFO'] = @path_info = m.post_match
        @path = real_path
      end
    end

    def check_forbidden
      forbidden = false
      forbidden = true if @path_info.include? ".."
      forbidden = true if @path_info =~ /\/?.+\/startup$/
      forbidden = true if @path_info =~ /\/?.+\/stop$/

      # breaks BVTs
      #forbidden = true if @path_info =~ /\/.+\/run\.pid/

      # Any symlink foolishness checked here
      check_path = @path.sub(/\/\s*$/,'')
      forbidden = true if (check_path != Pathname.new(@path).realpath.to_s)
      return unless forbidden

      body = "Not accessible\n"
      size = Rack::Utils.bytesize(body)
      return [403, {"Content-Type" => "text/plain",
                "Content-Length" => size.to_s,
                "X-Cascade" => "pass"}, [body]]
    end

    def list_directory
      @files = []
      glob = F.join(@path, '*')
      root = @path_info.sub(/^\/+/,'').empty?

      Dir[glob].sort.each do |node|
        stat = stat(node)
        next unless stat

        basename = F.basename(node)

        # ignore B29 control files, only return defaults
        next if root && (basename != 'app' && basename != 'logs' && basename != 'tomcat')
        size = stat.directory? ? '-' : filesize_format(stat.size)
        basename << '/'  if stat.directory?
        @files << [ basename, size ]
      end

      return [ 200, {'Content-Type'=>'text/plain'}, self ]
    end

    def stat(node, max = 10)
      F.stat(node)
    rescue Errno::ENOENT, Errno::ELOOP
      return nil
    end

    # TODO: add correct response if not readable, not sure if 404 is the best
    #       option
    def list_path
      @stat = F.stat(@path)

      if @stat.readable?
        return @app.call(@env) if @stat.file?
        return list_directory if @stat.directory?
      else
        raise Errno::ENOENT, 'No such file or directory'
      end

    rescue Errno::ENOENT, Errno::ELOOP
      return entity_not_found
    end

    def entity_not_found
      body = "Entity not found.\n"
      size = Rack::Utils.bytesize(body)
      return [404, {"Content-Type" => "text/plain",
                "Content-Length" => size.to_s,
                "X-Cascade" => "pass"}, [body]]
    end

    def each
      show_path = @path.sub(/^#{@root}/,'')
      files = @files.map{|f| "%-35s %10s" % f }*"\n"
      files.each_line{|l| yield l }
    end

    def logger
      @logger ||= self.class.logger
    end

    # Stolen from Ramaze

    FILESIZE_FORMAT = [
                       ['%.1fT', 1 << 40],
                       ['%.1fG', 1 << 30],
                       ['%.1fM', 1 << 20],
                       ['%.1fK', 1 << 10],
                      ]

    def filesize_format(int)
      FILESIZE_FORMAT.each do |format, size|
        return format % (int.to_f / size) if int >= size
      end
      int.to_s + 'B'
    end
  end
end
