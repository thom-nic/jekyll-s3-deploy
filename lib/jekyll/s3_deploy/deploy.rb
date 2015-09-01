# follow these instructions to setup your bucket:
# http://docs.amazonwebservices.com/AmazonS3/latest/dev/WebsiteHosting.html
# Customize values in _config_s3.yml as appropriate.

require 'aws-sdk'
require 'mime/types'
require 'yaml'
require 'zlib'

S3_CONFIG_FILE = "_config_s3.yml" # location of file with S3 access key, private key, bucket name

# Use `bin/jekyll deploy_s3` to upload any files that are newer locally than
# on S3.  Add `-f` to force upload.  
#
# Your S3 configuration should look like:
# ```yaml
# s3:
#   bucket: mysite.com
#   cache_control:
#   
#
# This uses http://docs.aws.amazon.com/sdkforruby/api/Aws/S3.html
class Jekyll::S3Deploy::DeployCommand < Jekyll::Command
  class << self
    def init_with_program prog
      prog.command(:deploy_s3) do |c|
        c.syntax "deploy_s3 [options]"
        c.description 'Upload the site to Amazon S3.'

        c.option 'include', '-i include_pattern', 'File pattern to include.'
        c.option 'force', '-f', 'Force all files to be re-uploaded'

        c.action do |args, options|
          s3_upload options['include'], options['force']
        end
      end
    end

    def s3_upload file_glob, force
      config = YAML.load File.open '_config.yml'

      begin
        s3_config = YAML.load File.open S3_CONFIG_FILE
        Aws.config.update(
          credentials: Aws::Credentials.new(
            s3_config['access_key'],
            s3_config['secret_key']
          ),
          region: config['s3']['region'] || 'us-east-1',
        )
      rescue Exception => e
        Jekyll.logger.error "Error: #{e}"
        Jekyll.logger.error "Please verify your AWS credentials in '#{S3_CONFIG_FILE}'"
        return
      end

      public_dir = config['destination'] || '_site'
      file_glob ||= '*'

      bucket = config['s3']['bucket']
      cache_control_map = config['s3']['cache_control'] || {}
      encoding_globs = config['s3']['deflate'] || []
      s3 = Aws::S3::Client.new

      Dir.glob("#{public_dir}/**/*") do |f|

        next if File.directory? f
        f_name = f.sub "#{public_dir}/", ""
        next unless File.fnmatch file_glob, f_name

        # compare atime for each file, only sync changes
        local_modified = Time.at File.stat( f ).mtime
        existing = begin
                     s3.head_object bucket: bucket, key: f_name
                   rescue Aws::S3::Errors::NotFound
                     nil  # file doesn't exist already on S3, no prob
                   end

        if force or not existing or existing.last_modified < local_modified
          Jekyll.logger.info "Pushing #{f_name} to #{bucket}..."
          File.open f, 'r' do |stream|

            stream, encoding = maybe_encode encoding_globs, f, stream
            cache_header = get_cache_header cache_control_map, f
            content_type_header = MIME::Types.type_for(f_name).first.content_type
            
            Jekyll.logger.debug "  Content-Encoding: #{encoding}" if encoding
            Jekyll.logger.debug "  Cache-Control: #{cache_header}" if cache_header

            s3.put_object key: f_name,
                          bucket: bucket,
                          body: stream,
                          acl: "public-read",
                          content_encoding: encoding,
                          cache_control: cache_header,
                          content_type: content_type_header
          end
        end
      end
    rescue Aws::Errors::ServiceError => e
      Jekyll.logger.error "AWS error: #{e.class}"
    end

    protected

    def maybe_encode globs, filename, raw_stream
      if globs.any? { |glob| File.fnmatch glob, filename }
        return Zlib::Deflate.deflate( raw_stream.read ), 'deflate'
      end
      return raw_stream, nil
    end

    # given a map of file globs to cache_control header values like
    # ```ruby
    # {
    #   '*.css' => 'public, expires=300',
    #   'assets/img/*' => 'public, expires=3600'
    # }
    # ```
    # this will return the first one that matches.
    def get_cache_header cache_map, filename
      cache_map.each do |glob,val|
        return val if File.fnmatch glob, filename
      end
    end
  end
end
