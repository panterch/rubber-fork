require 'erb'
require 'find'
require 'fileutils'

module Rubber
  module Configuration

    # Handles selection and transformation of a set of config files
    # based on the host/role they belong to
    class Generator
      attr_accessor :file_pattern
      attr_accessor :no_post
      attr_accessor :force
      attr_accessor :fake_root
      attr_accessor :stop_on_error_cmd

      def initialize(config_dir, roles, host, options={})
        @config_dir = config_dir
        @roles = roles.to_a.reverse #First roles take precedence
        @host = host || 'no_host'
        @options=options
      end

      def run
        config_dirs = []
        config_dirs << "#{@config_dir}/common/**/**"
        @roles.sort.each {|role| config_dirs <<  "#{@config_dir}/role/#{role}/**/**" }
        config_dirs << "#{@config_dir}/host/#{@host}/**/**"

        pat = Regexp.new(file_pattern) if file_pattern
        
        config_dirs.each do |dir|
          Dir[dir].sort.each do |f|
            next if f =~ /\/(CVS|\.svn)\//
            if File.file?(f) && (! pat || pat.match(f))
              LOGGER.info{"Transforming #{f}"}
              begin
                transform(IO.read(f), @options)
              rescue Exception => e
                lines = e.backtrace.grep(/^\(erb\):([0-9]+)/) {|b| Regexp.last_match(1) }
                LOGGER.error{"Transformation failed for #{f}#{':' + lines.first if lines.first}"}
                LOGGER.error e.message
                exit 1
              end
            end
          end
        end
      end

      # Transforms the ERB template given in srcfile and writes the result to
      # dest_file (if not nil) before returning it
      def transform(src_data, options={})
        config = ConfigDescriptor.new

        # for development/test, if we have a fake root, echo any
        # calls to system
        if fake_root
          class << config
            def system(*args)
              puts ("Not running system command during a fake_root transformation: #{args.inspect}")
            end
            def open(*args)
              if args.first && args.first =~ /^|/
                puts ("Not running open/pipe command during a fake_root transformation: #{args.inspect}")
              else
                super
              end
            end
            alias ` system
            alias exec system
            alias fork system
          end
        end

        config.options = options
        template = ERB.new(src_data)
        result = template.result(config.get_binding())

        config_path = config.path

        # for development/test, if we have a fake root, then send config
        # output there, and also put write_cmd output there
        if fake_root
          config_path = "write_cmd_" + config.write_cmd.gsub(/[^a-z0-9_-]/i, '') if config.write_cmd
          config_path = "#{fake_root}/#{config_path}" if config_path
        end

        if ! config_path && ! (config.read_cmd && config.write_cmd)
          raise "Transformation requires either a output filename or command"
        end

        reader = config_path || "|#{config.read_cmd}"
        orig = IO.read(reader) rescue ""

        # When additive is set we need to only replace between our delimiters
        if config.additive
          additive = ["# start rubber #{@host}", "# end rubber #{@host}"] unless additive.is_a? Array
          pat = /#{config.additive[0]}.*#{config.additive[1]}/m
          new = "#{config.additive[0]}#{result}#{config.additive[1]}"
          if orig =~ pat
            result = orig.gsub(pat, new)
          else
            result = orig + new + "\n"
          end
        end

        # Only do something if the transformed result is different than what
        # is currently in the destination file
        if orig != result || force
          # create dirs as needed
          FileUtils.mkdir_p(File.dirname(config_path)) if config_path

          # Write a backup of original
          open("#{config_path}.bak", 'w') { |f| f.write(orig) } if config_path

          # Write out transformed file
          writer = config_path || "|#{config.write_cmd}"
          open(writer, 'w') do |pipe|
            pipe.write(result)
          end
          if config.write_cmd && ! fake_root && $?.exitstatus != 0
            raise "Config command failed execution:  #{config.write_cmd}"
          end

          # Set file permissions and owner if needed
          FileUtils.chmod(config.perms, config_path) if config.perms && config_path
          FileUtils.chown(config.owner, config.group, config_path) if config_path && (config.owner || config.group)

          # Run post transform command if needed
          if config.post
            if orig == result
              LOGGER.info("Nothing to do, not running post command")
            elsif no_post
              LOGGER.info("Not running post command as no post specified")
            elsif fake_root
              LOGGER.info("Not running post command as a fake root was given: #{config.post}")
            else
              # this lets us abort a script if a command in the middle of it errors out
              # stop_on_error_cmd = "function error_exit { exit 99; }; trap error_exit ERR"
              config.post = "#{stop_on_error_cmd}\n#{config.post}" if stop_on_error_cmd

              LOGGER.info{"Transformation executing post config command: #{config.post}"}
              LOGGER.info `#{config.post}`
              if $?.exitstatus != 0
                raise "Post command failed execution:  #{config.post}"
              end
            end
          end
        end
      end

    end

    # Instances of this object are used accept settings from with
    # a config file for when it is transformed by Generator
    class ConfigDescriptor
      # The output path to write the transformed config file to
      attr_accessor :path
      # The command to use for reading the original config file from (e.g. "crontab -l")
      attr_accessor :read_cmd
      # The command to use for piping the transformed config file to (e.g. "crontab -")
      attr_accessor :write_cmd
      # The command to run after generating the config file if it has changed
      attr_accessor :post
      # The owner the output file should have, e.g. "root"
      attr_accessor :owner
      # The group the output file should have, e.g. "system"
      attr_accessor :group
      # The permissions the output file should have, e.g. 0644 (octal, leading zero is significant)
      attr_accessor :perms
      # Sets transformation to be additive, only replaces between given delimiters, e/g/ additive = ["## start", "## end"]
      attr_accessor :additive
      # use sudo to write the output file
      # attr_accessor :sudo
      # options passed in through code
      attr_accessor :options

      def get_binding
        binding
    end
    
    def rubber_env()
      Rubber::Configuration.rubber_env
    end
  
    def rubber_instances()
      Rubber::Configuration.rubber_instances
    end

    end

  end
end
