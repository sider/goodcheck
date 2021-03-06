module Goodcheck
  class ImportLoader
    class UnexpectedSchemaError < Error
      attr_reader :uri

      def initialize(uri)
        super("Unexpected URI schema: #{uri.scheme}")
        @uri = uri
      end
    end

    class FileNotFound < Error
      attr_reader :path

      def initialize(path)
        super("No such a file: #{path}")
        @path = path
      end
    end

    class HTTPGetError < Error
      attr_reader :response

      def initialize(res)
        super("HTTP GET #{res.uri} => #{res.code} #{res.message}")
        @response = res
      end
    end

    attr_reader :cache_path
    attr_reader :expires_in
    attr_reader :force_download
    attr_reader :config_path

    def initialize(cache_path:, expires_in: 3 * 60, force_download:, config_path:)
      @cache_path = cache_path
      @expires_in = expires_in
      @force_download = force_download
      @config_path = config_path
    end

    def load(name, &block)
      uri = begin
        URI.parse(name)
      rescue URI::InvalidURIError
        nil
      end

      case uri&.scheme
      when nil
        load_file name, &block
      when "file"
        load_file uri.path, &block
      when "http", "https"
        load_http uri, &block
      else
        raise UnexpectedSchemaError.new(uri)
      end
    end

    def load_file(path, &block)
      files = Pathname.glob(File.join(config_path.parent.to_path, path), File::FNM_DOTMATCH | File::FNM_EXTGLOB).sort
      if files.empty?
        raise FileNotFound.new(path)
      else
        files.each do |file|
          Goodcheck.logger.info "Reading file: #{file}"
          if unarchiver.tar_gz?(file)
            unarchiver.tar_gz(file.read) do |content, filename|
              block.call(content, filename)
            end
          else
            block.call(file.read, file.to_path)
          end
        end
      end
    end

    def cache_name(uri)
      Digest::SHA2.hexdigest(uri.to_s)
    end

    def load_http(uri, &block)
      hash = cache_name(uri)
      path = cache_path + hash

      Goodcheck.logger.info "Calculated cache name: #{hash}"

      download = false

      if force_download
        Goodcheck.logger.debug "Downloading: force flag"
        download = true
      end

      if !download && !path.file?
        Goodcheck.logger.debug "Downloading: no cache found"
        download = true
      end

      if !download && path.mtime + expires_in < Time.now
        Goodcheck.logger.debug "Downloading: cache expired"
        download = true
      end

      if download
        path.rmtree if path.exist?
        Goodcheck.logger.info "Downloading content..."
        if unarchiver.tar_gz?(uri.path)
          unarchiver.tar_gz(http_get(uri)) do |content, filename|
            block.call(content, filename)
            write_cache "#{uri}/#{filename}", content
          end
        else
          content = http_get(uri)
          block.call(content, uri.path)
          write_cache uri, content
        end
      else
        Goodcheck.logger.info "Reading content from cache..."
        block.call(path.read, path.to_path)
      end
    end

    def write_cache(uri, content)
      path = cache_path + cache_name(uri)
      path.write(content)
    end

    # @see https://ruby-doc.org/stdlib-2.7.0/libdoc/net/http/rdoc/Net/HTTP.html#class-Net::HTTP-label-Following+Redirection
    def http_get(uri, limit = 10)
      raise ArgumentError, "Too many HTTP redirects" if limit == 0

      max_retry_count = 2
      retry_count = 0
      begin
        res = Net::HTTP.get_response URI(uri)
        case res
        when Net::HTTPSuccess
          res.body
        when Net::HTTPRedirection
          location = res['Location']
          http_get location, limit - 1
        when Net::HTTPClientError, Net::HTTPServerError
          raise HTTPGetError.new(res)
        else
          raise Error, "HTTP GET failed due to #{res.inspect}"
        end
      rescue Net::OpenTimeout, HTTPGetError => exn
        if retry_count < max_retry_count
          retry_count += 1
          Goodcheck.logger.info "Retry ##{retry_count} - HTTP GET #{uri} due to #{exn.inspect}..."
          sleep 1
          retry
        else
          raise
        end
      end
    end

    private

    def unarchiver
      @unarchiver ||=
        begin
          filter = ->(filename) {
            %w[.yml .yaml].include?(File.extname(filename).downcase) && File.basename(filename) != DEFAULT_CONFIG_FILE
          }
          Unarchiver.new(file_filter: filter)
        end
    end
  end
end
